// filepath: tests/bridge-viewport.test.js
import { describe, expect, test, vi } from "vitest";
import { dispatch } from "../lib/bridge.js";

describe("viewport bridge", () => {
  test.each([undefined, 1])(
    "resizes without opening a CDP session when deviceScaleFactor is %s",
    async (deviceScaleFactor) => {
      const setViewportSize = vi.fn().mockResolvedValue(undefined);
      const browser = {
        getPage: () => ({ setViewportSize }),
      };

      const result = await dispatch(
        "viewport",
        { width: 1440, height: 1000, deviceScaleFactor },
        browser,
      );

      expect(setViewportSize).toHaveBeenCalledWith({ width: 1440, height: 1000 });
      expect(result.content).toHaveLength(1);
      expect(result.content[0].type).toBe("text");
      expect(JSON.parse(result.content[0].text)).toMatchObject({
        width: 1440,
        height: 1000,
      });
    },
  );
});
