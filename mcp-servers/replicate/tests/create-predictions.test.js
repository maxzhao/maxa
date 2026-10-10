"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const createPrediction = require("../tools/predictions/create-predictions.js");

function text(result) {
  return result.content[0].text;
}

test("create_predictions disables SDK retries for the non-idempotent POST", async () => {
  let receivedBody;
  let receivedOptions;
  const replicate = {
    predictions: {
      create: async (body, options) => {
        receivedBody = body;
        receivedOptions = options;
        return { id: "prediction-1", status: "starting" };
      },
    },
  };

  const result = await createPrediction.handler(replicate, {
    version: "version-1",
    Prefer: "wait=60",
    input: { prompt: "fixture" },
    jq_filter: "{id,status}",
  });

  assert.equal(receivedBody.version, "version-1");
  assert.equal(receivedBody.Prefer, "wait=60");
  assert.deepEqual(receivedOptions, { maxRetries: 0 });
  assert.deepEqual(JSON.parse(text(result)), { id: "prediction-1", status: "starting" });
});
