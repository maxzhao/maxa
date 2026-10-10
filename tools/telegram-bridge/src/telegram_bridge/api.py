from __future__ import annotations

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from .config import BridgeConfig
from .models import (
    ChatUploadCancelRequest,
    ChatUploadCreateRequest,
    HeartbeatRequest,
    HumanAssistCompleteRequest,
    HumanAssistInputRequest,
    HumanAssistNotifyRequest,
    HumanAssistNotificationEditRequest,
    HumanAssistPromptRequest,
    PollResponse,
    PollResponseEvent,
    RegisterInstanceRequest,
    TelegramEventResultRequest,
)
from .registry import Registry
from .security import constant_time_equal
from .store import Store
from .timeutil import now_ts
from .topic import NOTIFICATION_TOPIC_TITLE, TelegramTopicService, TopicResult, is_missing_topic_error


logger = logging.getLogger(__name__)
@dataclass(frozen=True)
class HumanAssistDestination:
    chat_id: int
    topic_id: int | None = None
    project_root: str | None = None
    save_id: str | None = None
    topic_title: str | None = None


def create_app(config: BridgeConfig, store: Store, topic_service: TelegramTopicService | None = None) -> FastAPI:
    app = FastAPI(title="Maxa Telegram Bridge", version="0.1.0")
    registry = Registry(store, config.heartbeat_ttl)
    topic_service = topic_service or TelegramTopicService(group_id=config.group_id)
    notification_topic_lock = asyncio.Lock()
    ask_topic_lock = asyncio.Lock()

    def require_token(x_maxa_bridge_token: str | None = Header(default=None)) -> None:
        if config.bridge_token and not constant_time_equal(x_maxa_bridge_token, config.bridge_token):
            raise HTTPException(status_code=401, detail="invalid bridge token")

    Auth = Depends(require_token)

    @app.get("/v1/health")
    def health() -> dict[str, object]:
        return {"ok": True, "time": now_ts()}

    @app.post("/v1/instances/register", dependencies=[Auth])
    def register(req: RegisterInstanceRequest) -> dict[str, object]:
        store.register_instance(instance_id=req.instance_id, pid=req.pid, cwd=req.cwd, project_root=req.project_root, version=req.version)
        return {"ok": True, "instance_id": req.instance_id}

    @app.post("/v1/instances/{instance_id}/heartbeat", dependencies=[Auth])
    def heartbeat(instance_id: str, req: HeartbeatRequest) -> dict[str, object]:
        store.heartbeat(instance_id=instance_id, open_chats=[chat.model_dump() for chat in req.open_chats])
        store.cancel_orphaned_chat_uploads(alive_after=registry.alive_after)
        return {"ok": True, "time": now_ts()}

    async def ensure_live_notification_topic(existing_topic_id: int | None, *, source: str) -> TopicResult:
        """Return a live group-scoped notification topic, not a Chat topic.

        Keep fallback notifications separate from ask/notify session topics.
        """
        if not existing_topic_id:
            topic = await topic_service.ensure_topic(title=NOTIFICATION_TOPIC_TITLE, existing_topic_id=None)
            logger.info("Telegram notification topic created", extra={"group_id": config.group_id, "topic_id": topic.topic_id, "source": source})
            return topic
        if hasattr(topic_service, "topic_exists"):
            try:
                exists = await topic_service.topic_exists(topic_id=existing_topic_id)  # type: ignore[attr-defined]
            except Exception as exc:
                if not is_missing_topic_error(exc):
                    raise
                exists = False
            if not exists:
                topic = await topic_service.ensure_topic(title=NOTIFICATION_TOPIC_TITLE, existing_topic_id=None)
                logger.warning("Telegram notification topic was stale; recreated", extra={"group_id": config.group_id, "old_topic_id": existing_topic_id, "topic_id": topic.topic_id, "source": source})
                return topic
        topic = await topic_service.ensure_topic(title=NOTIFICATION_TOPIC_TITLE, existing_topic_id=existing_topic_id)
        logger.debug("Telegram notification topic reused", extra={"group_id": config.group_id, "topic_id": topic.topic_id, "source": source})
        return topic

    async def ensure_notification_topic_id() -> int:
        if config.group_id is None:
            raise HTTPException(status_code=400, detail="group_id is not configured")
        async with notification_topic_lock:
            cached = store.get_notification_topic(config.group_id)
            cached_topic_id = int(cached["topic_id"]) if cached else None
            existing_topic_id = cached_topic_id or config.notification_topic_id
            source = "cache" if cached_topic_id else "config" if config.notification_topic_id else "create"
            topic = await ensure_live_notification_topic(existing_topic_id, source=source)
            store.set_notification_topic(group_id=config.group_id, topic_id=topic.topic_id, title=topic.title or NOTIFICATION_TOPIC_TITLE)
            return topic.topic_id

    def validate_human_assist_buttons(rows) -> None:
        if any(not row for row in rows) or sum(len(row) for row in rows) > 100:
            raise HTTPException(status_code=400, detail="buttons must contain 1-100 entries in non-empty rows")

    def chat_upload_response(row) -> dict[str, object]:
        response: dict[str, object] = {"request_id": row["request_id"], "session_id": row["session_id"], "status": row["status"]}
        if row["status"] == "completed":
            if row["result_path"]:
                response["path"] = row["result_path"]
            if row["result_text"]:
                response["text"] = row["result_text"]
        if row["status"] == "failed":
            response["error"] = {"code": row["error_code"] or "upload_failed", "message": row["error_message"] or "upload request failed"}
        return response

    def validate_chat_upload_caller(req: ChatUploadCreateRequest) -> None:
        caller = store.open_chat_for_instance(
            instance_id=req.instance_id,
            project_root=req.project_root,
            save_id=req.save_id,
            alive_after=registry.alive_after,
        )
        if not caller:
            raise HTTPException(status_code=409, detail="caller chat is not active")

    @app.post("/v1/chat-uploads", dependencies=[Auth])
    async def create_chat_upload(req: ChatUploadCreateRequest) -> dict[str, object]:
        validate_chat_upload_caller(req)
        destination = await resolve_ask_destination(req)
        request_id = uuid.uuid4().hex
        session_id = now_ts().__str__() + "-" + uuid.uuid4().hex[:12]
        store.create_chat_upload(request_id=request_id, instance_id=req.instance_id, project_root=req.project_root, save_id=req.save_id, session_id=session_id, chat_id=destination.chat_id, topic_id=destination.topic_id)
        prompt = "请回复此消息；可发送一个文件或纯文字。"
        try:
            destination, message_id = await send_human_assist(destination=destination, message=prompt, photo=None, parse_mode="", ask_route=True)
            if not store.attach_chat_upload_message(request_id, chat_id=destination.chat_id, topic_id=destination.topic_id, telegram_message_id=message_id):
                raise RuntimeError("upload request no longer creating")
        except Exception as exc:
            store.fail_chat_upload(request_id, code="telegram_send_failed", message="failed to send Telegram upload prompt")
            if isinstance(exc, HTTPException):
                raise
            raise HTTPException(status_code=503, detail="failed to send Telegram upload prompt") from exc
        return chat_upload_response(store.get_chat_upload(request_id))

    @app.get("/v1/chat-uploads/{request_id}", dependencies=[Auth])
    async def poll_chat_upload(request_id: str, timeout: int = Query(default=20, ge=0, le=30)) -> dict[str, object]:
        deadline = asyncio.get_event_loop().time() + timeout
        while True:
            row = store.get_chat_upload(request_id)
            if not row:
                raise HTTPException(status_code=404, detail="chat upload request not found")
            if row["status"] not in ("creating", "pending", "downloading") or asyncio.get_event_loop().time() >= deadline:
                return chat_upload_response(row)
            await asyncio.sleep(0.25)

    @app.post("/v1/chat-uploads/{request_id}/cancel", dependencies=[Auth])
    def cancel_chat_upload(request_id: str, req: ChatUploadCancelRequest) -> dict[str, object]:
        row = store.get_chat_upload(request_id)
        if not row:
            raise HTTPException(status_code=404, detail="chat upload request not found")
        if (row["instance_id"], row["project_root"], row["save_id"]) != (req.instance_id, req.project_root, req.save_id):
            raise HTTPException(status_code=403, detail="chat upload caller mismatch")
        store.cancel_chat_upload(request_id, instance_id=req.instance_id, project_root=req.project_root, save_id=req.save_id)
        return chat_upload_response(store.get_chat_upload(request_id))

    def human_assist_response(row) -> dict[str, object]:
        result = json.loads(row["result_json"]) if row["result_json"] else None
        return {
            "request_id": row["request_id"],
            "kind": row["kind"],
            "status": row["status"],
            "message_id": row["telegram_message_id"],
            "result": result,
        }

    def human_assist_markup(request_id: str, rows, *, single_column: bool = False) -> object:
        from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup

        keyboard = [
            [InlineKeyboardButton(text=button.text, callback_data=f"ha:{request_id}:{row_index}.{button_index}") for button_index, button in enumerate(row)]
            for row_index, row in enumerate(rows)
        ]
        if single_column:
            keyboard = [[button] for row in keyboard for button in row]
        return InlineKeyboardMarkup(inline_keyboard=keyboard)

    def human_assist_photo(photo: str):
        if photo.startswith("http://") or photo.startswith("https://"):
            return photo
        from aiogram.types import FSInputFile

        path = Path(photo).expanduser()
        if not path.is_file():
            raise HTTPException(status_code=400, detail="photo file not found")
        return FSInputFile(path)

    async def resolve_ask_destination(caller_context) -> HumanAssistDestination:
        if caller_context is None:
            raise HTTPException(status_code=400, detail="ask requires exact caller identity")
        if config.group_id is None:
            raise HTTPException(status_code=400, detail="group_id is not configured")
        private_human_assist_destination()  # Replies must still be owner-authorized.
        project_root, save_id = caller_context.project_root, caller_context.save_id
        async with ask_topic_lock:
            cached = store.get_ask_topic(project_root, save_id)
            if cached and int(cached["group_id"]) == config.group_id:
                return HumanAssistDestination(
                    chat_id=config.group_id, topic_id=int(cached["topic_id"]),
                    project_root=project_root, save_id=save_id,
                    topic_title=str(cached["topic_title"] or save_id),
                )
            title = store.get_open_chat_title(project_root, save_id) or save_id
            topic = await topic_service.ensure_topic(title=title, existing_topic_id=None)
            if not topic.topic_id:
                raise HTTPException(status_code=503, detail="Telegram group topic is unavailable")
            store.set_ask_topic(project_root, save_id, group_id=config.group_id, topic_id=topic.topic_id, topic_title=topic.title)
            return HumanAssistDestination(
                chat_id=config.group_id, topic_id=topic.topic_id,
                project_root=project_root, save_id=save_id,
                topic_title=topic.title,
            )

    def private_human_assist_destination() -> HumanAssistDestination:
        if config.owner_user_id is None:
            raise HTTPException(status_code=400, detail="owner_user_id is not configured")
        return HumanAssistDestination(chat_id=config.owner_user_id)

    def resolve_human_assist_destination(caller_context) -> HumanAssistDestination:
        # Legacy callers without explicit session-topic intent remain owner-private.
        return private_human_assist_destination()

    async def send_human_assist(
        *,
        destination: HumanAssistDestination,
        message: str,
        photo: str | None,
        parse_mode: str,
        silent: bool = False,
        reply_markup=None,
        request_id: str | None = None,
        ask_route: bool = False,
    ) -> tuple[HumanAssistDestination, int]:
        def persist_destination(target: HumanAssistDestination) -> None:
            if request_id:
                store.set_human_assist_destination(
                    request_id,
                    chat_id=target.chat_id,
                    topic_id=target.topic_id,
                )

        async def send(target: HumanAssistDestination) -> int | None:
            if photo:
                return await topic_service.send_photo(
                    chat_id=target.chat_id,
                    topic_id=target.topic_id,
                    photo=human_assist_photo(photo),
                    caption=message,
                    reply_markup=reply_markup,
                    parse_mode=parse_mode or None,
                    silent=silent,
                )
            return await topic_service.send_text(
                chat_id=target.chat_id,
                topic_id=target.topic_id,
                text=message,
                reply_markup=reply_markup,
                parse_mode=parse_mode or None,
                silent=silent,
            )

        persist_destination(destination)
        try:
            message_id = await send(destination)
        except Exception as exc:
            if not (destination.project_root and destination.save_id and destination.topic_id) or not is_missing_topic_error(exc):
                raise
            logger.warning("Human-assist topic is stale; attempting recovery")
            try:
                async with ask_topic_lock:
                    cached = store.get_ask_topic(destination.project_root, destination.save_id)
                    if cached and int(cached["group_id"]) == destination.chat_id and int(cached["topic_id"]) != destination.topic_id:
                        topic_id = int(cached["topic_id"])
                    else:
                        topic = await topic_service.ensure_topic(title=destination.topic_title, existing_topic_id=None)
                        if not topic.topic_id:
                            raise HTTPException(status_code=503, detail="Telegram group topic is unavailable")
                        topic_id = topic.topic_id
                        store.set_ask_topic(destination.project_root, destination.save_id, group_id=destination.chat_id, topic_id=topic_id, topic_title=topic.title)
                recovered = HumanAssistDestination(
                    chat_id=destination.chat_id, topic_id=topic_id,
                    project_root=destination.project_root, save_id=destination.save_id,
                    topic_title=destination.topic_title,
                )
                persist_destination(recovered)
                message_id = await send(recovered)
                destination = recovered
            except Exception as recovery_exc:
                if ask_route or not (is_missing_topic_error(recovery_exc) or isinstance(recovery_exc, HTTPException)):
                    raise
                logger.warning("Known unusable human-assist topic; using owner private chat")
                destination = private_human_assist_destination()
                persist_destination(destination)
                message_id = await send(destination)
        if message_id is None:
            raise HTTPException(status_code=503, detail="Telegram bot is unavailable")
        return destination, message_id

    async def close_human_assist_message(row, status_text: str) -> None:
        if row["telegram_message_id"] is None:
            return
        original = str(row["prompt_text"] or "").rstrip()
        try:
            await topic_service.edit_human_assist_message(
                chat_id=int(row["chat_id"]),
                message_id=int(row["telegram_message_id"]),
                text=f"{original}\n\n{status_text}" if original else status_text,
                has_photo=bool(json.loads(row["payload_json"]).get("photo")),
            )
        except Exception:
            logger.warning("failed to close human-assist message", exc_info=True)

    async def expire_human_assist(row) -> dict[str, object]:
        result = {"success": False, "error": "timeout", "elapsed": max(0, now_ts() - int(row["created_at"]))}
        if store.expire_human_assist_request(row["request_id"], result=result):
            await close_human_assist_message(row, "⌛ 等待响应已超时\n状态：该请求已关闭")
        return human_assist_response(store.get_human_assist_request(row["request_id"]))

    @app.post("/v1/human-assist/notify", dependencies=[Auth])
    async def human_assist_notify(req: HumanAssistNotifyRequest) -> dict[str, object]:
        if not req.message and not req.photo:
            raise HTTPException(status_code=400, detail="message or photo is required")
        destination = await resolve_ask_destination(req.caller_context) if req.ask_route else resolve_human_assist_destination(req.caller_context)
        _, message_id = await send_human_assist(
            destination=destination,
            message=req.message,
            photo=req.photo,
            parse_mode=req.parse_mode,
            silent=req.silent,
            ask_route=req.ask_route,
        )
        return {"success": True, "message_id": message_id}

    @app.post("/v1/human-assist/notify/edit", dependencies=[Auth])
    async def edit_human_assist_notification(req: HumanAssistNotificationEditRequest) -> dict[str, object]:
        # Cosmetic status only: never create/recover a topic or send a replacement.
        try:
            caller = req.caller_context
            cached = store.get_ask_topic(caller.project_root, caller.save_id)
            if (config.group_id is None or not cached
                or int(cached["group_id"]) != config.group_id or not cached["topic_id"]):
                return {"success": False}
            await asyncio.wait_for(
                topic_service.edit_human_assist_message(
                    chat_id=config.group_id, message_id=req.message_id, text=req.message,
                ),
                timeout=5,
            )
            return {"success": True}
        except Exception:
            # Missing/deleted messages, rate limits, timeouts and transport errors
            # do not affect the conversation and are deliberately not retried.
            return {"success": False}

    @app.post("/v1/human-assist/prompts", dependencies=[Auth])
    async def create_human_assist_prompt(req: HumanAssistPromptRequest) -> dict[str, object]:
        validate_human_assist_buttons(req.buttons)
        request_id = req.request_id or uuid.uuid4().hex
        if store.has_human_assist_cancellation(request_id):
            raise HTTPException(status_code=409, detail="human-assist request was cancelled before creation")
        if store.get_human_assist_request(request_id):
            raise HTTPException(status_code=409, detail="human-assist request id already exists")
        destination = await resolve_ask_destination(req.caller_context) if req.ask_route else resolve_human_assist_destination(req.caller_context)
        if store.has_human_assist_cancellation(request_id):
            raise HTTPException(status_code=409, detail="human-assist request was cancelled before creation")
        store.create_human_assist_request(
            request_id=request_id,
            kind="prompt",
            chat_id=destination.chat_id,
            topic_id=destination.topic_id,
            telegram_message_id=None,
            prompt_text=req.message,
            payload=req.model_dump(),
            expires_at=now_ts() + req.timeout if req.timeout > 0 else None,
        )
        try:
            destination, message_id = await send_human_assist(
                destination=destination,
                message=req.message,
                photo=req.photo,
                parse_mode=req.parse_mode,
                reply_markup=human_assist_markup(request_id, req.buttons, single_column=req.ask_route),
                request_id=request_id,
                ask_route=req.ask_route,
            )
        except Exception:
            store.delete_human_assist_request(request_id)
            raise
        attached = store.attach_human_assist_message(
            request_id,
            chat_id=destination.chat_id,
            topic_id=destination.topic_id,
            telegram_message_id=message_id,
        )
        row = store.get_human_assist_request(request_id)
        if not attached:
            shadow = dict(row)
            shadow["chat_id"] = destination.chat_id
            shadow["topic_id"] = destination.topic_id
            shadow["telegram_message_id"] = message_id
            await close_human_assist_message(shadow, "⏹️ 请求已取消\n状态：该请求已关闭")
        return human_assist_response(row)

    @app.post("/v1/human-assist/inputs", dependencies=[Auth])
    async def create_human_assist_input(req: HumanAssistInputRequest) -> dict[str, object]:
        request_id = req.request_id or uuid.uuid4().hex
        if store.has_human_assist_cancellation(request_id):
            raise HTTPException(status_code=409, detail="human-assist request was cancelled before creation")
        if store.get_human_assist_request(request_id):
            raise HTTPException(status_code=409, detail="human-assist request id already exists")
        destination = await resolve_ask_destination(req.caller_context) if req.ask_route else resolve_human_assist_destination(req.caller_context)
        if store.has_human_assist_cancellation(request_id):
            raise HTTPException(status_code=409, detail="human-assist request was cancelled before creation")
        prompt_text = req.message + "\n\n💬 请回复此消息来响应"
        store.create_human_assist_request(
            request_id=request_id,
            kind="input",
            chat_id=destination.chat_id,
            topic_id=destination.topic_id,
            telegram_message_id=None,
            prompt_text=prompt_text,
            payload=req.model_dump(),
            expires_at=now_ts() + req.timeout if req.timeout > 0 else None,
        )
        try:
            destination, message_id = await send_human_assist(
                destination=destination,
                message=prompt_text,
                photo=req.photo,
                parse_mode=req.parse_mode,
                request_id=request_id,
                ask_route=req.ask_route,
            )
        except Exception:
            store.delete_human_assist_request(request_id)
            raise
        attached = store.attach_human_assist_message(
            request_id,
            chat_id=destination.chat_id,
            topic_id=destination.topic_id,
            telegram_message_id=message_id,
        )
        row = store.get_human_assist_request(request_id)
        if not attached:
            shadow = dict(row)
            shadow["chat_id"] = destination.chat_id
            shadow["topic_id"] = destination.topic_id
            shadow["telegram_message_id"] = message_id
            await close_human_assist_message(shadow, "⏹️ 请求已取消\n状态：该请求已关闭")
        return human_assist_response(row)

    @app.get("/v1/human-assist/requests/{request_id}", dependencies=[Auth])
    async def poll_human_assist_request(request_id: str, timeout: int = Query(default=20, ge=0, le=30)) -> dict[str, object]:
        deadline = asyncio.get_event_loop().time() + timeout
        while True:
            row = store.get_human_assist_request(request_id)
            if not row:
                raise HTTPException(status_code=404, detail="human-assist request not found")
            if row["status"] != "pending":
                return human_assist_response(row)
            if row["expires_at"] is not None and now_ts() >= int(row["expires_at"]):
                return await expire_human_assist(row)
            if asyncio.get_event_loop().time() >= deadline:
                return human_assist_response(row)
            await asyncio.sleep(0.25)

    @app.post("/v1/human-assist/requests/{request_id}/complete", dependencies=[Auth])
    async def complete_human_assist_request(request_id: str, req: HumanAssistCompleteRequest) -> dict[str, object]:
        row = store.get_human_assist_request(request_id)
        if not row:
            raise HTTPException(status_code=404, detail="human-assist request not found")
        if store.complete_human_assist_request(
            request_id,
            result={"success": True, "source": req.source},
        ):
            await close_human_assist_message(row, "✅ 已在 Chat 中响应\n状态：该请求已关闭")
        return human_assist_response(store.get_human_assist_request(request_id))

    @app.post("/v1/human-assist/requests/{request_id}/cancel", dependencies=[Auth])
    async def cancel_human_assist_request(request_id: str) -> dict[str, object]:
        row = store.get_human_assist_request(request_id)
        if not row:
            store.reserve_human_assist_cancellation(request_id)
            return {
                "request_id": request_id,
                "status": "cancelled",
                "result": {"success": False, "error": "cancelled"},
            }
        result = {"success": False, "error": "cancelled"}
        if store.cancel_human_assist_request(request_id, result=result):
            await close_human_assist_message(row, "⏹️ 请求已取消\n状态：该请求已关闭")
        return human_assist_response(store.get_human_assist_request(request_id))

    @app.get("/v1/human-assist/files/{request_id}", dependencies=[Auth])
    async def download_human_assist_file(request_id: str):
        from fastapi.responses import Response

        row = store.get_human_assist_request(request_id)
        if not row or row["status"] != "completed" or not row["result_json"]:
            raise HTTPException(status_code=404, detail="human-assist file not found")
        result = json.loads(row["result_json"])
        file_id = result.get("photo_file_id")
        if not file_id:
            raise HTTPException(status_code=404, detail="human-assist response has no photo")
        content = await topic_service.download_file_bytes(file_id=str(file_id))
        return Response(content=content, media_type="application/octet-stream")

    def event_response(event) -> PollResponseEvent:
        payload = json.loads(event["payload_json"])
        return PollResponseEvent(
            event_id=int(event["id"]),
            type=event["event_type"],
            project_root=event["project_root"],
            save_id=event["save_id"],
            topic_id=int(event["topic_id"]),
            telegram_message_id=event["telegram_message_id"],
            text=str(payload.get("text") or ""),
            payload=payload,
        )

    @app.get("/v1/events/poll", response_model=PollResponse, dependencies=[Auth])
    async def poll(instance_id: str, timeout: int = 30) -> PollResponse:
        deadline = asyncio.get_event_loop().time() + max(0, min(timeout, config.poll_timeout))
        while True:
            delivered: list[PollResponseEvent] = []
            rows = store.list_live_open_chats(registry.alive_after)
            for row in rows:
                if row["instance_id"] != instance_id:
                    continue
                project_root = row["project_root"]
                save_id = row["save_id"]
                if registry.primary_for(project_root, save_id) != instance_id:
                    continue
                # Deliver at most one event per chat per poll. Neovim can only
                # submit one Telegram message into a CodeCompanion chat before
                # that chat becomes busy. If multiple events are marked
                # delivered in the same poll batch, later events cannot be
                # injected, are not acked, and then wait for delivery_timeout
                # before being retried. Keeping later events pending preserves
                # FIFO behavior for rapid Telegram bursts.
                for event in store.poll_events(project_root=project_root, save_id=save_id, limit=10):
                    store.mark_delivered(int(event["id"]))
                    delivered.append(event_response(event))
                    break
            if delivered or asyncio.get_event_loop().time() >= deadline:
                return PollResponse(events=delivered)
            await asyncio.sleep(0.5)

    @app.post("/v1/events/{event_id}/ack", dependencies=[Auth])
    def ack(event_id: int) -> dict[str, object]:
        store.ack_event(event_id)
        return {"ok": True}

    @app.post("/v1/events/{event_id}/result", dependencies=[Auth])
    async def event_result(event_id: int, req: TelegramEventResultRequest) -> dict[str, object]:
        event = store.get_event(event_id)
        if not event:
            raise HTTPException(status_code=404, detail="event not found")
        payload = json.loads(event["payload_json"])
        chat_id = req.chat_id or payload.get("reply_chat_id") or config.group_id
        topic_id = req.topic_id if req.topic_id is not None else payload.get("reply_topic_id")
        if not topic_id:
            topic_id = await ensure_notification_topic_id()
        reply_to_message_id = req.reply_to_message_id if req.reply_to_message_id is not None else payload.get("reply_message_id")
        text = req.message.strip() if req.message else ""
        if not text:
            text = "操作完成。" if req.ok else "操作失败。"
        try:
            await topic_service.send_text(chat_id=int(chat_id) if chat_id is not None else None, topic_id=int(topic_id or 0), text=text, reply_to_message_id=int(reply_to_message_id) if reply_to_message_id else None)
        except Exception as exc:
            if not is_missing_topic_error(exc) or not topic_id:
                raise
            logger.warning("Telegram event result reply topic is missing; falling back to notification topic", exc_info=True)
            fallback_topic_id = await ensure_notification_topic_id()
            await topic_service.send_text(chat_id=int(chat_id) if chat_id is not None else None, topic_id=fallback_topic_id, text=text, reply_to_message_id=None)
        return {"ok": True}

    app.state.store = store
    app.state.registry = registry
    return app
