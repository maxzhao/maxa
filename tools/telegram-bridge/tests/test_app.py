from __future__ import annotations

import asyncio

import pytest

from telegram_bridge import app as app_module
from telegram_bridge.config import BridgeConfig
from telegram_bridge.store import Store


@pytest.mark.asyncio
async def test_run_bot_retries_polling_start_failure(monkeypatch):
    calls = 0
    sleeps = []

    class FakeDispatcher:
        async def start_polling(self, bot):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise RuntimeError("proxy not ready")
            raise asyncio.CancelledError()

    def fake_build_dispatcher(config, store, topic_service):
        return FakeDispatcher()

    async def fake_sleep(delay):
        sleeps.append(delay)

    monkeypatch.setattr(app_module, "build_dispatcher", fake_build_dispatcher)
    monkeypatch.setattr(app_module.asyncio, "sleep", fake_sleep)

    store = Store(":memory:")
    try:
        with pytest.raises(asyncio.CancelledError):
            await app_module.run_bot(BridgeConfig(group_id=-100), store, object())
    finally:
        store.close()

    assert calls == 2
    assert sleeps == [app_module.BOT_RETRY_INITIAL_DELAY_SECONDS]
