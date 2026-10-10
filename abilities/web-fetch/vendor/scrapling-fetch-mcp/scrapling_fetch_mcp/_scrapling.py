from contextlib import redirect_stdout
from os import devnull
from typing import Any


async def browse_url(url: str, mode: str) -> Any:
    with open(devnull, "w") as nullfd, redirect_stdout(nullfd):
        from scrapling.fetchers import AsyncFetcher, StealthyFetcher

        if mode == "basic":
            return await AsyncFetcher.get(url, stealthy_headers=True)
        elif mode == "stealth":
            return await StealthyFetcher.async_fetch(
                url, headless=True, network_idle=True
            )
        elif mode == "max-stealth":
            return await StealthyFetcher.async_fetch(
                url,
                headless=True,
                block_webrtc=True,
                network_idle=True,
                disable_resources=False,
                block_images=False,
            )
        else:
            raise ValueError(f"Unknown mode: {mode}")
