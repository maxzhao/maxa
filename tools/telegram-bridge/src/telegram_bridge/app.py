from __future__ import annotations

import asyncio
import logging

import uvicorn

from .api import create_app
from .bot import build_dispatcher
from .config import BridgeConfig
from .store import Store
from .topic import TelegramTopicService


logger = logging.getLogger(__name__)
BOT_RETRY_INITIAL_DELAY_SECONDS = 5.0
BOT_RETRY_MAX_DELAY_SECONDS = 60.0


async def build_bot(config: BridgeConfig):
    if not config.bot_token:
        return None
    from aiogram import Bot
    from aiogram.client.session.aiohttp import AiohttpSession

    session = AiohttpSession(proxy=config.proxy) if config.proxy else None
    return Bot(token=config.bot_token, session=session)


async def run_bot(config: BridgeConfig, store: Store, bot) -> None:
    if not bot or (config.group_id is None and config.owner_user_id is None):
        return

    retry_delay = BOT_RETRY_INITIAL_DELAY_SECONDS
    while True:
        try:
            topic_service = TelegramTopicService(bot=bot, group_id=config.group_id)
            dispatcher = build_dispatcher(config, store, topic_service)
            await dispatcher.start_polling(bot)
            logger.warning("Telegram bot polling stopped unexpectedly; retrying in %.1fs", retry_delay)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Telegram bot polling failed; retrying in %.1fs", retry_delay)

        await asyncio.sleep(retry_delay)
        retry_delay = min(retry_delay * 2, BOT_RETRY_MAX_DELAY_SECONDS)


async def run_service(config: BridgeConfig) -> None:
    store = Store(config.sqlite_path)
    bot = await build_bot(config)
    topic_service = TelegramTopicService(bot=bot, group_id=config.group_id)
    app = create_app(config, store, topic_service)
    server = uvicorn.Server(uvicorn.Config(app, host=config.host, port=config.port, log_level="info"))
    bot_task = asyncio.create_task(run_bot(config, store, bot))
    try:
        await server.serve()
    finally:
        bot_task.cancel()
        try:
            await bot_task
        except asyncio.CancelledError:
            pass
        if bot is not None and getattr(bot, "session", None) is not None:
            await bot.session.close()
        store.close()


def build_app(config: BridgeConfig):
    store = Store(config.sqlite_path)
    return create_app(config, store)
