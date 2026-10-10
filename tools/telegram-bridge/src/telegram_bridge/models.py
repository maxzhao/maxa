from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field



class OpenChat(BaseModel):
    project_root: str
    save_id: str
    title: str | None = None
    adapter: str | None = None
    adapter_display_name: str | None = None
    model: str | None = None
    running: bool = False
    notify_active: bool = False
    message_count: int | None = None
    token_count: int | None = None
    token_limit: int | None = None
    token_percent: int | None = None
    balance_text: str | None = None


class RegisterInstanceRequest(BaseModel):
    instance_id: str
    pid: int | None = None
    cwd: str | None = None
    project_root: str | None = None
    version: str | None = None


class HeartbeatRequest(BaseModel):
    open_chats: list[OpenChat] = Field(default_factory=list)


class PollResponseEvent(BaseModel):
    event_id: int
    type: str
    project_root: str
    save_id: str
    topic_id: int
    telegram_message_id: int | None = None
    text: str
    payload: dict | None = None


class PollResponse(BaseModel):
    events: list[PollResponseEvent]


class TelegramEventResultRequest(BaseModel):
    ok: bool = True
    status: str | None = None
    message: str | None = None
    chat_id: int | None = None
    topic_id: int | None = None
    reply_to_message_id: int | None = None


class HumanAssistButton(BaseModel):
    text: str = Field(min_length=1, max_length=64)
    data: str = Field(min_length=1, max_length=256)


class HumanAssistCallerContext(BaseModel):
    project_root: str = Field(min_length=1, max_length=4096)
    save_id: str = Field(min_length=1, max_length=256)


class HumanAssistNotifyRequest(BaseModel):
    message: str = Field(default="", max_length=4096)
    ask_route: bool = False
    photo: str | None = Field(default=None, max_length=2048)
    parse_mode: Literal["", "Markdown", "HTML"] = ""
    silent: bool = False
    caller_context: HumanAssistCallerContext | None = None


class HumanAssistNotificationEditRequest(BaseModel):
    message_id: int = Field(gt=0)
    message: str = Field(min_length=1, max_length=4096)
    caller_context: HumanAssistCallerContext


class HumanAssistPromptRequest(BaseModel):
    ask_route: bool = False
    request_id: str | None = Field(default=None, min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")
    message: str = Field(min_length=1, max_length=4096)
    buttons: list[list[HumanAssistButton]] = Field(min_length=1, max_length=20)
    timeout: int = Field(default=60, ge=0, le=86400)
    photo: str | None = Field(default=None, max_length=2048)
    parse_mode: Literal["", "Markdown", "HTML"] = ""
    caller_context: HumanAssistCallerContext | None = None


class HumanAssistInputRequest(BaseModel):
    ask_route: bool = False
    request_id: str | None = Field(default=None, min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")
    message: str = Field(min_length=1, max_length=4096)
    timeout: int = Field(default=120, ge=0, le=86400)
    photo: str | None = Field(default=None, max_length=2048)
    parse_mode: Literal["", "Markdown", "HTML"] = ""
    caller_context: HumanAssistCallerContext | None = None


class HumanAssistCompleteRequest(BaseModel):
    source: Literal["chat"]


class ChatUploadCreateRequest(BaseModel):
    instance_id: str = Field(min_length=1, max_length=256)
    project_root: str = Field(min_length=1, max_length=4096)
    save_id: str = Field(min_length=1, max_length=256)


class ChatUploadCancelRequest(ChatUploadCreateRequest):
    pass
