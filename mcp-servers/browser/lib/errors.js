// filepath: lib/errors.js
// Error formatting utilities for browser MCP Server

/**
 * Format an error into MCP error response
 * @param {string} action - The action that failed
 * @param {Error|string} error - The error
 * @returns {object} MCP content response with isError flag
 */
export function formatError(action, error) {
  const message = error instanceof Error ? error.message : String(error);
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify({ error: true, action, message }),
      },
    ],
    isError: true,
  };
}

/**
 * Format a success result into MCP response
 * @param {any} data - The data to return
 * @returns {object} MCP content response
 */
export function formatSuccess(data) {
  const text =
    typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return {
    content: [{ type: "text", text }],
  };
}
