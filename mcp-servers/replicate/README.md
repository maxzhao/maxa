# Replicate MCP server

This is the npm package for Replicate's official MCP server.

You can run it locally or use the hosted version at [mcp.replicate.com](https://mcp.replicate.com).

To get started, go to [replicate.com/docs/reference/mcp](https://replicate.com/docs/reference/mcp).

You can find more nitty-gritty details about this package below, but you probably don't need to read them!

---

## Installation

### Direct invocation

You can run the MCP server directly via `npx`.

Create a Replicate API token at [replicate.com/account/api-tokens](https://replicate.com/account/api-tokens?new-token-name=mcp-server), then run:

```sh
export REPLICATE_API_TOKEN="My Bearer Token"
npx -y replicate-mcp@latest
```

### Via MCP Client

There is a partial list of existing clients at [modelcontextprotocol.io](https://modelcontextprotocol.io/clients). If you already
have a client, consult their documentation to install the MCP server.

For clients with a configuration JSON, it might look something like this:

```json
{
  "mcpServers": {
    "replicate": {
      "command": "npx",
      "args": ["-y", "replicate-mcp", "--client=claude", "--tools=dynamic"],
      "env": {
        "REPLICATE_API_TOKEN": "My Bearer Token"
      }
    }
  }
}
```

### Cursor

If you use Cursor, you can install the MCP server by using the button below. You will need to set your environment variables
in Cursor's `mcp.json`, which can be found in Cursor Settings > Tools & MCP > New MCP Server.

[![Add to Cursor](https://cursor.com/deeplink/mcp-install-dark.svg)](https://cursor.com/en-US/install-mcp?name=replicate-mcp&config=eyJjb21tYW5kIjoibnB4IiwiYXJncyI6WyIteSIsInJlcGxpY2F0ZS1tY3AiXSwiZW52Ijp7IlJFUExJQ0FURV9BUElfVE9LRU4iOiJTZXQgeW91ciBSRVBMSUNBVEVfQVBJX1RPS0VOIGhlcmUuIn19)

### VS Code

If you use MCP, you can install the MCP server by clicking the link below. You will need to set your environment variables
in VS Code's `mcp.json`, which can be found via Command Palette > MCP: Open User Configuration.

[Open VS Code](https://vscode.stainless.com/mcp/%7B%22name%22%3A%22replicate-mcp%22%2C%22command%22%3A%22npx%22%2C%22args%22%3A%5B%22-y%22%2C%22replicate-mcp%22%5D%2C%22env%22%3A%7B%22REPLICATE_API_TOKEN%22%3A%22Set%20your%20REPLICATE_API_TOKEN%20here.%22%7D%7D)

### Claude Code

If you use Claude Code, you can install the MCP server by running the command below in your terminal. You will need to set your
environment variables in Claude Code's `.claude.json`, which can be found in your home directory.

```
claude mcp add --transport stdio replicate_api --env REPLICATE_API_TOKEN="Your REPLICATE_API_TOKEN here." -- npx -y replicate-mcp
```

## Exposing endpoints to your MCP Client

There are three ways to expose endpoints as tools in the MCP server:

1. Exposing one tool per endpoint, and filtering as necessary
2. Exposing a set of tools to dynamically discover and invoke endpoints from the API
3. Exposing a docs search tool and a code execution tool, allowing the client to write code to be executed against the TypeScript client

### Filtering endpoints and tools

You can run the package on the command line to discover and filter the set of tools that are exposed by the
MCP Server. This can be helpful for large APIs where including all endpoints at once is too much for your AI's
context window.

You can filter by multiple aspects:

- `--tool` includes a specific tool by name
- `--resource` includes all tools under a specific resource, and can have wildcards, e.g. `my.resource*`
- `--operation` includes just read (get/list) or just write operations

### Dynamic tools

If you specify `--tools=dynamic` to the MCP server, instead of exposing one tool per endpoint in the API, it will
expose the following tools:

1. `list_api_endpoints` - Discovers available endpoints, with optional filtering by search query
2. `get_api_endpoint_schema` - Gets detailed schema information for a specific endpoint
3. `invoke_api_endpoint` - Executes any endpoint with the appropriate parameters

This allows you to have the full set of API endpoints available to your MCP Client, while not requiring that all
of their schemas be loaded into context at once. Instead, the LLM will automatically use these tools together to
search for, look up, and invoke endpoints dynamically. However, due to the indirect nature of the schemas, it
can struggle to provide the correct properties a bit more than when tools are imported explicitly. Therefore,
you can opt-in to explicit tools, the dynamic tools, or both.

See more information with `--help`.

All of these command-line options can be repeated, combined together, and have corresponding exclusion versions (e.g. `--no-tool`).

Use `--list` to see the list of available tools, or see below.

### Code execution

If you specify `--tools=code` to the MCP server, it will expose just two tools:

- `search_docs` - Searches the API documentation and returns a list of markdown results
- `execute` - Runs code against the TypeScript client

This allows the LLM to implement more complex logic by chaining together many API calls without loading
intermediary results into its context window.

The code execution itself happens in a Deno sandbox that has network access only to the base URL for the API.

### Specifying the MCP Client

Different clients have varying abilities to handle arbitrary tools and schemas.

You can specify the client you are using with the `--client` argument, and the MCP server will automatically
serve tools and schemas that are more compatible with that client.

- `--client=<type>`: Set all capabilities based on a known MCP client

  - Valid values: `openai-agents`, `claude`, `claude-code`, `cursor`
  - Example: `--client=cursor`

Additionally, if you have a client not on the above list, or the client has gotten better
over time, you can manually enable or disable certain capabilities:

- `--capability=<name>`: Specify individual client capabilities
  - Available capabilities:
    - `top-level-unions`: Enable support for top-level unions in tool schemas
    - `valid-json`: Enable JSON string parsing for arguments
    - `refs`: Enable support for $ref pointers in schemas
    - `unions`: Enable support for union types (anyOf) in schemas
    - `formats`: Enable support for format validations in schemas (e.g. date-time, email)
    - `tool-name-length=N`: Set maximum tool name length to N characters
  - Example: `--capability=top-level-unions --capability=tool-name-length=40`
  - Example: `--capability=top-level-unions,tool-name-length=40`

### Examples

1. Filter for read operations on cards:

```bash
--resource=cards --operation=read
```

2. Exclude specific tools while including others:

```bash
--resource=cards --no-tool=create_cards
```

3. Configure for Cursor client with custom max tool name length:

```bash
--client=cursor --capability=tool-name-length=40
```

4. Complex filtering with multiple criteria:

```bash
--resource=cards,accounts --operation=read --tag=kyc --no-tool=create_cards
```

## Running remotely

Launching the client with `--transport=http` launches the server as a remote server using Streamable HTTP transport. The `--port` setting can choose the port it will run on, and the `--socket` setting allows it to run on a Unix socket.

Authorization can be provided via the `Authorization` header using the Bearer scheme.

Additionally, authorization can be provided via the following headers:
| Header | Equivalent client option | Security scheme |
| ----------------------- | ------------------------ | --------------- |
| `x-replicate-api-token` | `bearerToken` | bearerAuth |

A configuration JSON for this server might look like this, assuming the server is hosted at `http://localhost:3000`:

```json
{
  "mcpServers": {
    "replicate_api": {
      "url": "http://localhost:3000",
      "headers": {
        "Authorization": "Bearer <auth value>"
      }
    }
  }
}
```

The command-line arguments for filtering tools and specifying clients can also be used as query parameters in the URL.
For example, to exclude specific tools while including others, use the URL:

```
http://localhost:3000?resource=cards&resource=accounts&no_tool=create_cards
```

Or, to configure for the Cursor client, with a custom max tool name length, use the URL:

```
http://localhost:3000?client=cursor&capability=tool-name-length%3D40
```

## Importing the tools and server individually

```js
// Import the server, generated endpoints, or the init function
import { server, endpoints, init } from "replicate-mcp/server";

// import a specific tool
import search from "replicate-mcp/tools/top-level/search";

// initialize the server and all endpoints
init({ server, endpoints });

// manually start server
const transport = new StdioServerTransport();
await server.connect(transport);

// or initialize your own server with specific tools
const myServer = new McpServer(...);

// define your own endpoint
const myCustomEndpoint = {
  tool: {
    name: 'my_custom_tool',
    description: 'My custom tool',
    inputSchema: zodToJsonSchema(z.object({ a_property: z.string() })),
  },
  handler: async (client: replicate, args: any) => {
    return { myResponse: 'Hello world!' };
  })
};

// initialize the server with your custom endpoints
init({ server: myServer, endpoints: [search, myCustomEndpoint] });
```

## Available Tools

The following tools are available in this MCP server.

### Resource `$client`:

- `search` (`read`): Search for public models, collections, and docs using a text query.

  For models, the response includes all model data, plus a new `metadata` object with the following fields:

  - `generated_description`: A longer and more detailed AI-generated description of the model
  - `tags`: An array of tags for the model
  - `score`: A score for the model's relevance to the search query

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    "https://api.replicate.com/v1/search?query=nano+banana"
  ```

  Note: This search API is currently in beta and may change in future versions.

### Resource `collections`:

- `list_collections` (`read`): Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/collections
  ```

  The response will be a paginated JSON list of collection objects:

  ```json
  {
    "next": "null",
    "previous": null,
    "results": [
      {
        "name": "Super resolution",
        "slug": "super-resolution",
        "description": "Upscaling models that create high-quality images from low-quality images."
      }
    ]
  }
  ```

- `get_collections` (`read`): Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/collections/super-resolution
  ```

  The response will be a collection object with a nested list of the models in that collection:

  ```json
  {
    "name": "Super resolution",
    "slug": "super-resolution",
    "description": "Upscaling models that create high-quality images from low-quality images.",
    "full_description": "## Overview\n\nThese models generate high-quality images from low-quality images. Many of these models are based on **advanced upscaling techniques**.\n\n### Key Features\n\n- Enhance image resolution\n- Restore fine details\n- Improve overall image quality",
    "models": [...]
  }
  ```

### Resource `deployments`:

- `create_deployments` (`write`): Create a new deployment:

  Example cURL request:

  ```console
  curl -s \
    -X POST \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
          "name": "my-app-image-generator",
          "model": "stability-ai/sdxl",
          "version": "da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf",
          "hardware": "gpu-t4",
          "min_instances": 0,
          "max_instances": 3
        }' \
    https://api.replicate.com/v1/deployments
  ```

  The response will be a JSON object describing the deployment:

  ```json
  {
    "owner": "acme",
    "name": "my-app-image-generator",
    "current_release": {
      "number": 1,
      "model": "stability-ai/sdxl",
      "version": "da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf",
      "created_at": "2024-02-15T16:32:57.018467Z",
      "created_by": {
        "type": "organization",
        "username": "acme",
        "name": "Acme Corp, Inc.",
        "avatar_url": "https://cdn.replicate.com/avatars/acme.png",
        "github_url": "https://github.com/acme"
      },
      "configuration": {
        "hardware": "gpu-t4",
        "min_instances": 1,
        "max_instances": 5
      }
    }
  }
  ```

- `update_deployments` (`write`): Update properties of an existing deployment, including hardware, min/max instances, and the deployment's underlying model [version](https://replicate.com/docs/how-does-replicate-work#versions).

  Example cURL request:

  ```console
  curl -s \
    -X PATCH \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"min_instances": 3, "max_instances": 10}' \
    https://api.replicate.com/v1/deployments/acme/my-app-image-generator
  ```

  The response will be a JSON object describing the deployment:

  ```json
  {
    "owner": "acme",
    "name": "my-app-image-generator",
    "current_release": {
      "number": 2,
      "model": "stability-ai/sdxl",
      "version": "da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf",
      "created_at": "2024-02-15T16:32:57.018467Z",
      "created_by": {
        "type": "organization",
        "username": "acme",
        "name": "Acme Corp, Inc.",
        "avatar_url": "https://cdn.replicate.com/avatars/acme.png",
        "github_url": "https://github.com/acme"
      },
      "configuration": {
        "hardware": "gpu-t4",
        "min_instances": 3,
        "max_instances": 10
      }
    }
  }
  ```

  Updating any deployment properties will increment the `number` field of the `current_release`.

- `list_deployments` (`read`): Get a list of deployments associated with the current account, including the latest release configuration for each deployment.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/deployments
  ```

  The response will be a paginated JSON array of deployment objects, sorted with the most recent deployment first:

  ```json
  {
    "next": "http://api.replicate.com/v1/deployments?cursor=cD0yMDIzLTA2LTA2KzIzJTNBNDAlM0EwOC45NjMwMDAlMkIwMCUzQTAw",
    "previous": null,
    "results": [
      {
        "owner": "replicate",
        "name": "my-app-image-generator",
        "current_release": {
          "number": 1,
          "model": "stability-ai/sdxl",
          "version": "da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf",
          "created_at": "2024-02-15T16:32:57.018467Z",
          "created_by": {
            "type": "organization",
            "username": "acme",
            "name": "Acme Corp, Inc.",
            "avatar_url": "https://cdn.replicate.com/avatars/acme.png",
            "github_url": "https://github.com/acme"
          },
          "configuration": {
            "hardware": "gpu-t4",
            "min_instances": 1,
            "max_instances": 5
          }
        }
      }
    ]
  }
  ```

- `get_deployments` (`read`): Get information about a deployment by name including the current release.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/deployments/replicate/my-app-image-generator
  ```

  The response will be a JSON object describing the deployment:

  ```json
  {
    "owner": "acme",
    "name": "my-app-image-generator",
    "current_release": {
      "number": 1,
      "model": "stability-ai/sdxl",
      "version": "da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf",
      "created_at": "2024-02-15T16:32:57.018467Z",
      "created_by": {
        "type": "organization",
        "username": "acme",
        "name": "Acme Corp, Inc.",
        "avatar_url": "https://cdn.replicate.com/avatars/acme.png",
        "github_url": "https://github.com/acme"
      },
      "configuration": {
        "hardware": "gpu-t4",
        "min_instances": 1,
        "max_instances": 5
      }
    }
  }
  ```

### Resource `deployments.predictions`:

- `create_deployments_predictions` (`write`): Create a prediction for the deployment and inputs you provide.

  Example cURL request:

  ```console
  curl -s -X POST -H 'Prefer: wait' \
    -d '{"input": {"prompt": "A photo of a bear riding a bicycle over the moon"}}' \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    -H 'Content-Type: application/json' \
    https://api.replicate.com/v1/deployments/acme/my-app-image-generator/predictions
  ```

  The request will wait up to 60 seconds for the model to run. If this time is exceeded the prediction will be returned in a `"starting"` state and need to be retrieved using the `predictions.get` endpoint.

  For a complete overview of the `deployments.predictions.create` API check out our documentation on [creating a prediction](https://replicate.com/docs/topics/predictions/create-a-prediction) which covers a variety of use cases.

### Resource `hardware`:

- `list_hardware` (`read`): Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/hardware
  ```

  The response will be a JSON array of hardware objects:

  ```json
  [
    { "name": "CPU", "sku": "cpu" },
    { "name": "Nvidia T4 GPU", "sku": "gpu-t4" },
    { "name": "Nvidia A40 GPU", "sku": "gpu-a40-small" },
    { "name": "Nvidia A40 (Large) GPU", "sku": "gpu-a40-large" }
  ]
  ```

### Resource `account`:

- `get_account` (`read`): Returns information about the user or organization associated with the provided API token.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/account
  ```

  The response will be a JSON object describing the account:

  ```json
  {
    "type": "organization",
    "username": "acme",
    "name": "Acme Corp, Inc.",
    "github_url": "https://github.com/acme"
  }
  ```

### Resource `models`:

- `create_models` (`write`): Create a model.

  Example cURL request:

  ```console
  curl -s -X POST \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"owner": "alice", "name": "hot-dog-detector", "description": "Detect hot dogs in images", "visibility": "public", "hardware": "cpu"}' \
    https://api.replicate.com/v1/models
  ```

  The response will be a model object in the following format:

  ```json
  {
    "url": "https://replicate.com/alice/hot-dog-detector",
    "owner": "alice",
    "name": "hot-dog-detector",
    "description": "Detect hot dogs in images",
    "visibility": "public",
    "github_url": null,
    "paper_url": null,
    "license_url": null,
    "run_count": 0,
    "cover_image_url": null,
    "default_example": null,
    "latest_version": null
  }
  ```

  Note that there is a limit of 1,000 models per account. For most purposes, we recommend using a single model and pushing new [versions](https://replicate.com/docs/how-does-replicate-work#versions) of the model as you make changes to it.

- `update_models` (`write`): Update select properties of an existing model.

  You can update the following properties:

  - `description` - Model description
  - `readme` - Model README content
  - `github_url` - GitHub repository URL
  - `paper_url` - Research paper URL
  - `weights_url` - Model weights URL
  - `license_url` - License URL

  Example cURL request:

  ```console
  curl -X PATCH \
    https://api.replicate.com/v1/models/your-username/your-model-name \
    -H "Authorization: Token $REPLICATE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "description": "Detect hot dogs in images",
      "readme": "# Hot Dog Detector\n\n🌭 Ketchup, mustard, and onions...",
      "github_url": "https://github.com/alice/hot-dog-detector",
      "paper_url": "https://arxiv.org/abs/2504.17639",
      "weights_url": "https://huggingface.co/alice/hot-dog-detector",
      "license_url": "https://choosealicense.com/licenses/mit/"
    }'
  ```

  The response will be the updated model object with all of its properties.

- `list_models` (`read`): Get a paginated list of public models.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/models
  ```

  The response will be a pagination object containing a list of model objects.

  See the [`models.get`](#models.get) docs for more details about the model object.

  ## Sorting

  You can sort the results using the `sort_by` and `sort_direction` query parameters.

  For example, to get the most recently created models:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    "https://api.replicate.com/v1/models?sort_by=model_created_at&sort_direction=desc"
  ```

  Available sorting options:

  - `model_created_at`: Sort by when the model was first created
  - `latest_version_created_at`: Sort by when the model's latest version was created (default)

  Sort direction can be `asc` (ascending) or `desc` (descending, default).

- `get_models` (`read`): Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/models/replicate/hello-world
  ```

  The response will be a model object in the following format:

  ```json
  {
    "url": "https://replicate.com/replicate/hello-world",
    "owner": "replicate",
    "name": "hello-world",
    "description": "A tiny model that says hello",
    "visibility": "public",
    "github_url": "https://github.com/replicate/cog-examples",
    "paper_url": null,
    "license_url": null,
    "run_count": 5681081,
    "cover_image_url": "...",
    "default_example": {...},
    "latest_version": {...},
  }
  ```

  The model object includes the [input and output schema](https://replicate.com/docs/reference/openapi#model-schemas) for the latest version of the model.

  Here's an example showing how to fetch the model with cURL and display its input schema with [jq](https://stedolan.github.io/jq/):

  ```console
  curl -s \
      -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
      https://api.replicate.com/v1/models/replicate/hello-world \
      | jq ".latest_version.openapi_schema.components.schemas.Input"
  ```

  This will return the following JSON object:

  ```json
  {
    "type": "object",
    "title": "Input",
    "required": ["text"],
    "properties": {
      "text": {
        "type": "string",
        "title": "Text",
        "x-order": 0,
        "description": "Text to prefix with 'hello '"
      }
    }
  }
  ```

  The `cover_image_url` string is an HTTPS URL for an image file. This can be:

  - An image uploaded by the model author.
  - The output file of the example prediction, if the model author has not set a cover image.
  - The input file of the example prediction, if the model author has not set a cover image and the example prediction has no output file.
  - A generic fallback image.

  The `default_example` object is a [prediction](#predictions.get) created with this model.

  The `latest_version` object is the model's most recently pushed [version](#models.versions.get).

### Resource `models.examples`:

- `list_models_examples` (`read`): List [example predictions](https://replicate.com/docs/topics/models/publish-a-model#what-are-examples) made using the model.
  These are predictions that were saved by the model author as illustrative examples of the model's capabilities.

  If you want all the examples for a model, use this operation.

  If you just want the model's default example, you can use the [`models.get`](#models.get) operation instead, which includes a `default_example` object.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/models/replicate/hello-world/examples
  ```

  The response will be a pagination object containing a list of example predictions:

  ```json
  {
    "next": "https://api.replicate.com/v1/models/replicate/hello-world/examples?cursor=...",
    "previous": "https://api.replicate.com/v1/models/replicate/hello-world/examples?cursor=...",
    "results": [...]
  }
  ```

  Each item in the `results` list is a [prediction object](#predictions.get).

### Resource `models.predictions`:

- `create_models_predictions` (`write`): Create a prediction using an [official model](https://replicate.com/changelog/2025-01-29-official-models).

  If you're _not_ running an official model, use the [`predictions.create`](#predictions.create) operation instead.

  Example cURL request:

  ```console
  curl -s -X POST -H 'Prefer: wait' \
    -d '{"input": {"prompt": "Write a short poem about the weather."}}' \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    -H 'Content-Type: application/json' \
    https://api.replicate.com/v1/models/meta/meta-llama-3-70b-instruct/predictions
  ```

  The request will wait up to 60 seconds for the model to run. If this time is exceeded the prediction will be returned in a `"starting"` state and need to be retrieved using the `predictions.get` endpoint.

  For a complete overview of the `deployments.predictions.create` API check out our documentation on [creating a prediction](https://replicate.com/docs/topics/predictions/create-a-prediction) which covers a variety of use cases.

### Resource `models.readme`:

- `get_models_readme` (`read`): Get the README content for a model.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/models/replicate/hello-world/readme
  ```

  The response will be the README content as plain text in Markdown format:

  ```
  # Hello World Model

  This is an example model that...
  ```

### Resource `models.versions`:

- `list_models_versions` (`read`): Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/models/replicate/hello-world/versions
  ```

  The response will be a JSON array of model version objects, sorted with the most recent version first:

  ```json
  {
    "next": null,
    "previous": null,
    "results": [
      {
        "id": "5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa",
        "created_at": "2022-04-26T19:29:04.418669Z",
        "cog_version": "0.3.0",
        "openapi_schema": {...}
      }
    ]
  }
  ```

- `get_models_versions` (`read`): Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/models/replicate/hello-world/versions/5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa
  ```

  The response will be the version object:

  ```json
  {
    "id": "5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa",
    "created_at": "2022-04-26T19:29:04.418669Z",
    "cog_version": "0.3.0",
    "openapi_schema": {...}
  }
  ```

  Every model describes its inputs and outputs with [OpenAPI Schema Objects](https://spec.openapis.org/oas/latest.html#schemaObject) in the `openapi_schema` property.

  The `openapi_schema.components.schemas.Input` property for the [replicate/hello-world](https://replicate.com/replicate/hello-world) model looks like this:

  ```json
  {
    "type": "object",
    "title": "Input",
    "required": ["text"],
    "properties": {
      "text": {
        "x-order": 0,
        "type": "string",
        "title": "Text",
        "description": "Text to prefix with 'hello '"
      }
    }
  }
  ```

  The `openapi_schema.components.schemas.Output` property for the [replicate/hello-world](https://replicate.com/replicate/hello-world) model looks like this:

  ```json
  {
    "type": "string",
    "title": "Output"
  }
  ```

  For more details, see the docs on [Cog's supported input and output types](https://github.com/replicate/cog/blob/75b7802219e7cd4cee845e34c4c22139558615d4/docs/python.md#input-and-output-types)

### Resource `predictions`:

- `create_predictions` (`write`): Create a prediction for the model version and inputs you provide.

  Example cURL request:

  ```console
  curl -s -X POST -H 'Prefer: wait' \
    -d '{"version": "replicate/hello-world:5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa", "input": {"text": "Alice"}}' \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    -H 'Content-Type: application/json' \
    https://api.replicate.com/v1/predictions
  ```

  The request will wait up to 60 seconds for the model to run. If this time is exceeded the prediction will be returned in a `"starting"` state and need to be retrieved using the `predictions.get` endpoint.

  For a complete overview of the `predictions.create` API check out our documentation on [creating a prediction](https://replicate.com/docs/topics/predictions/create-a-prediction) which covers a variety of use cases.

- `list_predictions` (`read`): Get a paginated list of all predictions created by the user or organization associated with the provided API token.

  This will include predictions created from the API and the website. It will return 100 records per page.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/predictions
  ```

  The response will be a paginated JSON array of prediction objects, sorted with the most recent prediction first:

  ```json
  {
    "next": null,
    "previous": null,
    "results": [
      {
        "completed_at": "2023-09-08T16:19:34.791859Z",
        "created_at": "2023-09-08T16:19:34.907244Z",
        "data_removed": false,
        "error": null,
        "id": "gm3qorzdhgbfurvjtvhg6dckhu",
        "input": {
          "text": "Alice"
        },
        "metrics": {
          "predict_time": 0.012683
        },
        "output": "hello Alice",
        "started_at": "2023-09-08T16:19:34.779176Z",
        "source": "api",
        "status": "succeeded",
        "urls": {
          "web": "https://replicate.com/p/gm3qorzdhgbfurvjtvhg6dckhu",
          "get": "https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu",
          "cancel": "https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu/cancel"
        },
        "model": "replicate/hello-world",
        "version": "5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa"
      }
    ]
  }
  ```

  `id` will be the unique ID of the prediction.

  `source` will indicate how the prediction was created. Possible values are `web` or `api`.

  `status` will be the status of the prediction. Refer to [get a single prediction](#predictions.get) for possible values.

  `urls` will be a convenience object that can be used to construct new API requests for the given prediction. If the requested model version supports streaming, this will have a `stream` entry with an HTTPS URL that you can use to construct an [`EventSource`](https://developer.mozilla.org/en-US/docs/Web/API/EventSource).

  `model` will be the model identifier string in the format of `{model_owner}/{model_name}`.

  `version` will be the unique ID of model version used to create the prediction.

  `data_removed` will be `true` if the input and output data has been deleted.

- `cancel_predictions` (`write`): Cancel a prediction that is currently running.

  Example cURL request that creates a prediction and then cancels it:

  ```console
  # First, create a prediction
  PREDICTION_ID=$(curl -s -X POST \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "input": {
        "prompt": "a video that may take a while to generate"
      }
    }' \
    https://api.replicate.com/v1/models/minimax/video-01/predictions | jq -r '.id')

  # Echo the prediction ID
  echo "Created prediction with ID: $PREDICTION_ID"

  # Cancel the prediction
  curl -s -X POST \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/predictions/$PREDICTION_ID/cancel
  ```

- `get_predictions` (`read`): Get the current state of a prediction.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu
  ```

  The response will be the prediction object:

  ```json
  {
    "id": "gm3qorzdhgbfurvjtvhg6dckhu",
    "model": "replicate/hello-world",
    "version": "5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa",
    "input": {
      "text": "Alice"
    },
    "logs": "",
    "output": "hello Alice",
    "error": null,
    "status": "succeeded",
    "created_at": "2023-09-08T16:19:34.765994Z",
    "data_removed": false,
    "started_at": "2023-09-08T16:19:34.779176Z",
    "completed_at": "2023-09-08T16:19:34.791859Z",
    "metrics": {
      "predict_time": 0.012683
    },
    "urls": {
      "web": "https://replicate.com/p/gm3qorzdhgbfurvjtvhg6dckhu",
      "get": "https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu",
      "cancel": "https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu/cancel"
    }
  }
  ```

  `status` will be one of:

  - `starting`: the prediction is starting up. If this status lasts longer than a few seconds, then it's typically because a new worker is being started to run the prediction.
  - `processing`: the `predict()` method of the model is currently running.
  - `succeeded`: the prediction completed successfully.
  - `failed`: the prediction encountered an error during processing.
  - `canceled`: the prediction was canceled by its creator.

  In the case of success, `output` will be an object containing the output of the model. Any files will be represented as HTTPS URLs. You'll need to pass the `Authorization` header to request them.

  In the case of failure, `error` will contain the error encountered during the prediction.

  Terminated predictions (with a status of `succeeded`, `failed`, or `canceled`) will include a `metrics` object with a `predict_time` property showing the amount of CPU or GPU time, in seconds, that the prediction used while running. It won't include time waiting for the prediction to start. The `metrics` object will also include a `total_time` property showing the total time, in seconds, that the prediction took to complete.

  All input parameters, output values, and logs are automatically removed after an hour, by default, for predictions created through the API.

  You must save a copy of any data or files in the output if you'd like to continue using them. The `output` key will still be present, but it's value will be `null` after the output has been removed.

  Output files are served by `replicate.delivery` and its subdomains. If you use an allow list of external domains for your assets, add `replicate.delivery` and `*.replicate.delivery` to it.

### Resource `trainings`:

- `create_trainings` (`write`): Start a new training of the model version you specify.

  Example request body:

  ```json
  {
    "destination": "{new_owner}/{new_name}",
    "input": {
      "train_data": "https://example.com/my-input-images.zip"
    },
    "webhook": "https://example.com/my-webhook"
  }
  ```

  Example cURL request:

  ```console
  curl -s -X POST \
    -d '{"destination": "{new_owner}/{new_name}", "input": {"input_images": "https://example.com/my-input-images.zip"}}' \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    -H 'Content-Type: application/json' \
    https://api.replicate.com/v1/models/stability-ai/sdxl/versions/da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf/trainings
  ```

  The response will be the training object:

  ```json
  {
    "id": "zz4ibbonubfz7carwiefibzgga",
    "model": "stability-ai/sdxl",
    "version": "da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf",
    "input": {
      "input_images": "https://example.com/my-input-images.zip"
    },
    "logs": "",
    "error": null,
    "status": "starting",
    "created_at": "2023-09-08T16:32:56.990893084Z",
    "urls": {
      "web": "https://replicate.com/p/zz4ibbonubfz7carwiefibzgga",
      "get": "https://api.replicate.com/v1/predictions/zz4ibbonubfz7carwiefibzgga",
      "cancel": "https://api.replicate.com/v1/predictions/zz4ibbonubfz7carwiefibzgga/cancel"
    }
  }
  ```

  As models can take several minutes or more to train, the result will not be available immediately. To get the final result of the training you should either provide a `webhook` HTTPS URL for us to call when the results are ready, or poll the [get a training](#trainings.get) endpoint until it has finished.

  When a training completes, it creates a new [version](https://replicate.com/docs/how-does-replicate-work#terminology) of the model at the specified destination.

  To find some models to train on, check out the [trainable language models collection](https://replicate.com/collections/trainable-language-models).

- `list_trainings` (`read`): Get a paginated list of all trainings created by the user or organization associated with the provided API token.

  This will include trainings created from the API and the website. It will return 100 records per page.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/trainings
  ```

  The response will be a paginated JSON array of training objects, sorted with the most recent training first:

  ```json
  {
    "next": null,
    "previous": null,
    "results": [
      {
        "completed_at": "2023-09-08T16:41:19.826523Z",
        "created_at": "2023-09-08T16:32:57.018467Z",
        "error": null,
        "id": "zz4ibbonubfz7carwiefibzgga",
        "input": {
          "input_images": "https://example.com/my-input-images.zip"
        },
        "metrics": {
          "predict_time": 502.713876
        },
        "output": {
          "version": "...",
          "weights": "..."
        },
        "started_at": "2023-09-08T16:32:57.112647Z",
        "source": "api",
        "status": "succeeded",
        "urls": {
          "web": "https://replicate.com/p/zz4ibbonubfz7carwiefibzgga",
          "get": "https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga",
          "cancel": "https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga/cancel"
        },
        "model": "stability-ai/sdxl",
        "version": "da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf"
      }
    ]
  }
  ```

  `id` will be the unique ID of the training.

  `source` will indicate how the training was created. Possible values are `web` or `api`.

  `status` will be the status of the training. Refer to [get a single training](#trainings.get) for possible values.

  `urls` will be a convenience object that can be used to construct new API requests for the given training.

  `version` will be the unique ID of model version used to create the training.

- `cancel_trainings` (`write`): Cancel a training
- `get_trainings` (`read`): Get the current state of a training.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga
  ```

  The response will be the training object:

  ```json
  {
    "completed_at": "2023-09-08T16:41:19.826523Z",
    "created_at": "2023-09-08T16:32:57.018467Z",
    "error": null,
    "id": "zz4ibbonubfz7carwiefibzgga",
    "input": {
      "input_images": "https://example.com/my-input-images.zip"
    },
    "logs": "...",
    "metrics": {
      "predict_time": 502.713876
    },
    "output": {
      "version": "...",
      "weights": "..."
    },
    "started_at": "2023-09-08T16:32:57.112647Z",
    "status": "succeeded",
    "urls": {
      "web": "https://replicate.com/p/zz4ibbonubfz7carwiefibzgga",
      "get": "https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga",
      "cancel": "https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga/cancel"
    },
    "model": "stability-ai/sdxl",
    "version": "da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf"
  }
  ```

  `status` will be one of:

  - `starting`: the training is starting up. If this status lasts longer than a few seconds, then it's typically because a new worker is being started to run the training.
  - `processing`: the `train()` method of the model is currently running.
  - `succeeded`: the training completed successfully.
  - `failed`: the training encountered an error during processing.
  - `canceled`: the training was canceled by its creator.

  In the case of success, `output` will be an object containing the output of the model. Any files will be represented as HTTPS URLs. You'll need to pass the `Authorization` header to request them.

  In the case of failure, `error` will contain the error encountered during the training.

  Terminated trainings (with a status of `succeeded`, `failed`, or `canceled`) will include a `metrics` object with a `predict_time` property showing the amount of CPU or GPU time, in seconds, that the training used while running. It won't include time waiting for the training to start. The `metrics` object will also include a `total_time` property showing the total time, in seconds, that the training took to complete.

### Resource `webhooks.default.secret`:

- `get_default_webhooks_secret` (`read`): Get the signing secret for the default webhook endpoint. This is used to verify that webhook requests are coming from Replicate.

  Example cURL request:

  ```console
  curl -s \
    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
    https://api.replicate.com/v1/webhooks/default/secret
  ```

  The response will be a JSON object with a `key` property:

  ```json
  {
    "key": "..."
  }
  ```
