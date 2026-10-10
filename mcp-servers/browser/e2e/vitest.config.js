// filepath: e2e/vitest.config.js
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 60000,
    hookTimeout: 45000,
    // Use threads with single thread to share app instance across test files
    pool: "threads",
    poolOptions: {
      threads: {
        singleThread: true,
      },
    },
    include: ["e2e/**/*.test.js"],
    setupFiles: ["e2e/setup.js"],
  },
});
