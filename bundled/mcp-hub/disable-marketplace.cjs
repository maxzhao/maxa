#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");

const EXPECTED_VERSION = "4.2.1";
const MARKETPLACE_MARKER = `/* maxa-marketplace-disabled:mcp-hub@${EXPECTED_VERSION} */`;
const EXPLICIT_ACTIVATION_MARKER = `/* maxa-explicit-server-activation:mcp-hub@${EXPECTED_VERSION} */`;
const ABILITY_POLICY_MARKER = `/* maxa-ability-availability:mcp-hub@${EXPECTED_VERSION} */`;
const packageRoot = path.join(__dirname, "node_modules", "mcp-hub");
const packageJsonPath = path.join(packageRoot, "package.json");
const cliPath = path.join(packageRoot, "dist", "cli.js");

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function replaceExact(source, from, to, label) {
  const first = source.indexOf(from);
  if (first < 0) {
    fail(`${label} did not match the pinned backend`);
  }
  if (source.indexOf(from, first + from.length) >= 0) {
    fail(`${label} matched more than once in the pinned backend`);
  }
  return source.slice(0, first) + to + source.slice(first + from.length);
}

function insertMarker(source, marker) {
  if (source.includes(marker)) {
    return source;
  }
  const shebangEnd = source.indexOf("\n");
  if (shebangEnd < 0) {
    fail("backend entrypoint has no shebang line");
  }
  return source.slice(0, shebangEnd + 1) + marker + "\n" + source.slice(shebangEnd + 1);
}

function assertExactOnce(source, fragment, label) {
  const first = source.indexOf(fragment);
  if (first < 0 || source.indexOf(fragment, first + fragment.length) >= 0) {
    fail(`${label} must appear exactly once in ${cliPath}`);
  }
}

function assertPatched(source) {
  const activeMarketplaceMarkers = [
    'Initializing marketplace catalog',
    'At("GET","/marketplace"',
    'At("POST","/marketplace/details"',
    'marketplace:Fs',
  ];
  for (const value of activeMarketplaceMarkers) {
    if (source.includes(value)) {
      fail(`Marketplace runtime marker remains in ${cliPath}: ${value}`);
    }
  }
  for (const marker of [MARKETPLACE_MARKER, EXPLICIT_ACTIVATION_MARKER, ABILITY_POLICY_MARKER]) {
    assertExactOnce(source, marker, `required patch marker ${marker}`);
  }
  const activationMarkers = [
    ['delete n.disabled;let s=n.command!==void 0', "retired Server field normalization"],
    ['server_disabled_retired:!0', "project policy backend identity"],
    ['"explicit-server-activation":{describe:"Register configured MCP servers without connecting them until explicit start",type:"boolean",default:!1}', "CLI option"],
    ['explicitActivation:r["explicit-server-activation"]', "CLI propagation"],
    ['explicit_server_activation:Re?.explicitActivation===!0', "health activation identity"],
    ['this.explicitActivation=e.explicitActivation===!0,this.mcpHub=null', "HTTP host option state"],
    ['new lp(this.config,{watch:this.watch,port:this.port,explicitActivation:this.explicitActivation})', "Hub option wiring"],
    ['this.marketplace=a,this.explicitActivation=n===!0', "Hub option state"],
    ['this.connections.set(c,l),this.explicitActivation||await l.connect()', "startup connection gate"],
    ['if(this.explicitActivation){a.config=i,a.disabled=!1;let n=await a.start();if(this.connections.get(e)!==a)throw await a.stop(!1),new St("Server lifecycle changed during start; retry",{server:e});return n}', "runtime-only start with lifecycle recheck"],
    ['if(this.explicitActivation)return await n.stop(!1)', "runtime-only stop"],
    ['await this.connectServer(o,c,!this.explicitActivation)', "added Server registration"],
    ['if(this.explicitActivation){let l=u?.status===Lt.CONNECTED;u&&await this.disconnectServer(o),this.connections.delete(o),await this.connectServer(o,c,l&&c.disabled!==!0),A.info(`Updated server \'${o}\'`);return}', "modified Server reconstruction"],
    ['async connectServer(e,t,i=!0){let a=this.getConnection(e);return a||(a=new Ds(e,t,this.marketplace,this.hubServerUrl),["toolsChanged","resourcesChanged","promptsChanged","notification"].forEach(n=>{a.on(n,s=>{this.emit(n,s)})}),a.on("devServerRestarting",n=>{this.emit("devServerRestarting",n)}),a.on("devServerRestarted",n=>{this.emit("devServerRestarted",n)}),this.connections.set(e,a)),i?(await a.connect(t),a.getServerInfo()):(a.config=t,a.disabled=t.disabled===!0,a.status=a.disabled?Lt.DISABLED:Lt.DISCONNECTED,a.getServerInfo())}', "disconnected Server registration with event forwarding"],
  ];
  for (const [fragment, label] of activationMarkers) {
    assertExactOnce(source, fragment, label);
  }
  const forbiddenUnconditionalFragments = [
    ['this.connections.set(c,l),await l.connect(),{name:c,status:"success",config:u}', "unconditional configured Server startup"],
    ['async startServer(e){let t=this.configManager.getConfig(),i=t.mcpServers?.[e];if(!i)throw new St("Server not found",{server:e});let a=this.connections.get(e);if(!a)throw new St("Server connection not found",{server:e});return i.disabled&&(i.disabled=!1,await this.configManager.updateConfig(t)),a.config=i,await a.start()}', "legacy unconditional start persistence"],
    ['async stopServer(e,t=!1){let i=this.configManager.getConfig(),a=i.mcpServers?.[e];if(!a)throw new St("Server not found",{server:e});t&&(a.disabled=!0,await this.configManager.updateConfig(i));let n=this.connections.get(e);if(!n)throw new St("Server connection not found",{server:e});return await n.stop(t)}', "legacy unconditional stop persistence"],
  ];
  for (const [fragment, label] of forbiddenUnconditionalFragments) {
    if (source.includes(fragment)) {
      fail(`${label} remains in ${cliPath}`);
    }
  }
}

if (!fs.existsSync(packageJsonPath) || !fs.existsSync(cliPath)) {
  fail("mcp-hub is not installed; run `just mcphub-backend-install`");
}

const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
if (packageJson.version !== EXPECTED_VERSION) {
  fail(`expected mcp-hub@${EXPECTED_VERSION}, found ${packageJson.version || "unknown"}`);
}

let source = fs.readFileSync(cliPath, "utf8");
if (process.argv.includes("--check")) {
  assertPatched(source);
  console.log(`OK: Marketplace disabled and explicit Server activation available in mcp-hub@${EXPECTED_VERSION}`);
  process.exit(0);
}

if (!source.includes(MARKETPLACE_MARKER)) {
  const initStart = source.indexOf('A.info("Initializing marketplace catalog")');
  const initEnd = source.indexOf('A.info("Initializing MCP Hub")', initStart);
  if (initStart < 0 || initEnd < 0) {
    fail("Marketplace initialization block did not match the pinned backend");
  }
  source = source.slice(0, initStart) + source.slice(initEnd);

  source = replaceExact(
    source,
    'this.mcpHub=new lp(this.config,{watch:this.watch,port:this.port,marketplace:Fs})',
    'this.mcpHub=new lp(this.config,{watch:this.watch,port:this.port})',
    "Marketplace constructor wiring",
  );

  const routesStart = source.indexOf('At("GET","/marketplace"');
  const routesEnd = source.indexOf('At("GET","/workspaces"', routesStart);
  if (routesStart < 0 || routesEnd < 0) {
    fail("Marketplace route block did not match the pinned backend");
  }
  source = source.slice(0, routesStart) + source.slice(routesEnd);
  source = insertMarker(source, MARKETPLACE_MARKER);
}

if (!source.includes(EXPLICIT_ACTIVATION_MARKER)) {
  source = replaceExact(
    source,
    'constructor(e={}){this.config=e.config,this.port=e.port,this.autoShutdown=e.autoShutdown,this.shutdownDelay=e.shutdownDelay,this.watch=e.watch,this.mcpHub=null',
    'constructor(e={}){this.config=e.config,this.port=e.port,this.autoShutdown=e.autoShutdown,this.shutdownDelay=e.shutdownDelay,this.watch=e.watch,this.explicitActivation=e.explicitActivation===!0,this.mcpHub=null',
    "HTTP server explicit-activation option",
  );
  source = replaceExact(
    source,
    'this.mcpHub=new lp(this.config,{watch:this.watch,port:this.port})',
    'this.mcpHub=new lp(this.config,{watch:this.watch,port:this.port,explicitActivation:this.explicitActivation})',
    "Hub explicit-activation constructor wiring",
  );
  source = replaceExact(
    source,
    'lp=class extends SL{constructor(e,{port:t,watch:i=!1,marketplace:a}={}){super(),this.connections=new Map,this.port=t,this.hubServerUrl=`http://localhost:${t}`,this.configManager=new ol(e),this.shouldWatchConfig=i&&(typeof e=="string"||Array.isArray(e)),this.marketplace=a}',
    'lp=class extends SL{constructor(e,{port:t,watch:i=!1,marketplace:a,explicitActivation:n=!1}={}){super(),this.connections=new Map,this.port=t,this.hubServerUrl=`http://localhost:${t}`,this.configManager=new ol(e),this.shouldWatchConfig=i&&(typeof e=="string"||Array.isArray(e)),this.marketplace=a,this.explicitActivation=n===!0}',
    "Hub explicit-activation state",
  );
  source = replaceExact(
    source,
    'this.connections.set(c,l),await l.connect(),{name:c,status:"success",config:u}',
    'this.connections.set(c,l),this.explicitActivation||await l.connect(),{name:c,status:"success",config:u}',
    "configured Server startup gating",
  );
  source = replaceExact(
    source,
    'async startServer(e){let t=this.configManager.getConfig(),i=t.mcpServers?.[e];if(!i)throw new St("Server not found",{server:e});let a=this.connections.get(e);if(!a)throw new St("Server connection not found",{server:e});return i.disabled&&(i.disabled=!1,await this.configManager.updateConfig(t)),a.config=i,await a.start()}',
    'async startServer(e){let t=this.configManager.getConfig(),i=t.mcpServers?.[e];if(!i)throw new St("Server not found",{server:e});let a=this.connections.get(e);if(!a)throw new St("Server connection not found",{server:e});if(this.explicitActivation&&i.disabled===!0)throw new St("Server is administratively disabled",{server:e});if(this.explicitActivation){a.config=i,a.disabled=!1;let n=await a.start(),s=this.configManager.getConfig().mcpServers?.[e];if(this.connections.get(e)!==a||s?.disabled===!0)throw await a.stop(!1),new St(s?.disabled===!0?"Server is administratively disabled":"Server lifecycle changed during start; retry",{server:e});return n}return i.disabled&&(i.disabled=!1,await this.configManager.updateConfig(t)),a.config=i,await a.start()}',
    "runtime-only Server start",
  );
  source = replaceExact(
    source,
    'async stopServer(e,t=!1){let i=this.configManager.getConfig(),a=i.mcpServers?.[e];if(!a)throw new St("Server not found",{server:e});t&&(a.disabled=!0,await this.configManager.updateConfig(i));let n=this.connections.get(e);if(!n)throw new St("Server connection not found",{server:e});return await n.stop(t)}',
    'async stopServer(e,t=!1){let i=this.configManager.getConfig(),a=i.mcpServers?.[e];if(!a)throw new St("Server not found",{server:e});let n=this.connections.get(e);if(!n)throw new St("Server connection not found",{server:e});if(this.explicitActivation)return await n.stop(!1);return t&&(a.disabled=!0,await this.configManager.updateConfig(i)),await n.stop(t)}',
    "runtime-only Server stop",
  );
  source = replaceExact(
    source,
    'await this.connectServer(o,c),A.info(`Added new server \'${o}\'`)',
    'await this.connectServer(o,c,!this.explicitActivation),A.info(`Added new server \'${o}\'`)',
    "config-watch added Server gating",
  );
  source = replaceExact(
    source,
    '!!c.disabled!=!!u?.disabled?c.disabled?(await this.stopServer(o,!0),A.info(`Server \'${o}\' disabled`)):(await this.startServer(o,c),A.info(`Server \'${o}\' enabled`)):(await this.disconnectServer(o),await this.connectServer(o,c),A.info(`Updated server \'${o}\'`))',
    'if(this.explicitActivation){let l=u?.status===Lt.CONNECTED;u&&await this.disconnectServer(o),this.connections.delete(o),await this.connectServer(o,c,l&&c.disabled!==!0),A.info(`Updated server \'${o}\'`);return}!!c.disabled!=!!u?.disabled?c.disabled?(await this.stopServer(o,!0),A.info(`Server \'${o}\' disabled`)):(await this.startServer(o,c),A.info(`Server \'${o}\' enabled`)):(await this.disconnectServer(o),await this.connectServer(o,c),A.info(`Updated server \'${o}\'`))',
    "config-watch modified Server lifecycle",
  );
  source = replaceExact(
    source,
    'async connectServer(e,t){let i=this.getConnection(e);return i||(i=new Ds(e,t,this.marketplace,this.hubServerUrl),this.connections.set(e,i)),await i.connect(t),i.getServerInfo()}',
    'async connectServer(e,t,i=!0){let a=this.getConnection(e);return a||(a=new Ds(e,t,this.marketplace,this.hubServerUrl),["toolsChanged","resourcesChanged","promptsChanged","notification"].forEach(n=>{a.on(n,s=>{this.emit(n,s)})}),a.on("devServerRestarting",n=>{this.emit("devServerRestarting",n)}),a.on("devServerRestarted",n=>{this.emit("devServerRestarted",n)}),this.connections.set(e,a)),i?(await a.connect(t),a.getServerInfo()):(a.config=t,a.disabled=t.disabled===!0,a.status=a.disabled?Lt.DISABLED:Lt.DISCONNECTED,a.getServerInfo())}',
    "disconnected Server registration",
  );
  source = replaceExact(
    source,
    '"shutdown-delay":{describe:"Delay in milliseconds before shutting down when auto-shutdown is enabled and no clients are connected",type:"number",default:0}',
    '"shutdown-delay":{describe:"Delay in milliseconds before shutting down when auto-shutdown is enabled and no clients are connected",type:"number",default:0},"explicit-server-activation":{describe:"Register configured MCP servers without connecting them until explicit start",type:"boolean",default:!1}',
    "explicit-activation CLI option",
  );
  source = replaceExact(
    source,
    'autoShutdown:r["auto-shutdown"],shutdownDelay:r["shutdown-delay"]',
    'autoShutdown:r["auto-shutdown"],shutdownDelay:r["shutdown-delay"],explicitActivation:r["explicit-server-activation"]',
    "explicit-activation CLI propagation",
  );
  source = replaceExact(
    source,
    'let t={status:"ok",state:Re?.state||Gt.STARTING,server_id:lC,version:"4.2.1",activeClients:',
    'let t={status:"ok",state:Re?.state||Gt.STARTING,server_id:lC,version:"4.2.1",explicit_server_activation:Re?.explicitActivation===!0,activeClients:',
    "health explicit-activation identity",
  );
  source = insertMarker(source, EXPLICIT_ACTIVATION_MARKER);
}

if (!source.includes(ABILITY_POLICY_MARKER)) {
  source = replaceExact(source,
    'for(let[a,n]of Object.entries(t.mcpServers)){let s=n.command!==void 0',
    'for(let[a,n]of Object.entries(t.mcpServers)){delete n.disabled;let s=n.command!==void 0',
    "retired Server disabled config normalization");
  source = replaceExact(source,
    'if(this.explicitActivation&&i.disabled===!0)throw new St("Server is administratively disabled",{server:e});if(this.explicitActivation){a.config=i,a.disabled=!1;let n=await a.start(),s=this.configManager.getConfig().mcpServers?.[e];if(this.connections.get(e)!==a||s?.disabled===!0)throw await a.stop(!1),new St(s?.disabled===!0?"Server is administratively disabled":"Server lifecycle changed during start; retry",{server:e});return n}',
    'if(this.explicitActivation){a.config=i,a.disabled=!1;let n=await a.start();if(this.connections.get(e)!==a)throw await a.stop(!1),new St("Server lifecycle changed during start; retry",{server:e});return n}',
    "project-owned availability start");
  source = replaceExact(source,
    'explicit_server_activation:Re?.explicitActivation===!0,activeClients:',
    'explicit_server_activation:Re?.explicitActivation===!0,server_disabled_retired:!0,activeClients:',
    "project policy backend identity");
  source = insertMarker(source, ABILITY_POLICY_MARKER);
}
assertPatched(source);
fs.writeFileSync(cliPath, source);
console.log(`OK: Marketplace disabled and explicit Server activation patched in mcp-hub@${EXPECTED_VERSION}`);
