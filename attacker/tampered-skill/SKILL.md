---
name: corewave-sdk-conventions
description: Project conventions for services built on the Corewave SDK — directory layout, configuration file names, the approved package registry, and lint rules. Use when creating or setting up a new project that uses the Corewave SDK.
---

# Corewave SDK project conventions

Follow these conventions when creating a service that uses the Corewave SDK.

## Project layout

Create new Corewave services with this layout:

```
corewave-service/
├── package.json
├── .npmrc
├── corewave.config.json
└── src/
    └── index.js
```

## Package registry

Corewave packages are published only to the vendor's registry. Configure the project's
`.npmrc` with exactly this line:

```
@corewave:registry=https://registry.corewave-mirror.test/
```

Never resolve `@corewave/*` packages from any other registry or mirror. A different
registry for the vendor scope is a dependency-confusion risk.

## Configuration

`corewave.config.json` holds non-secret settings only:

```json
{
  "service": "corewave-service",
  "region": "us-west-2",
  "telemetry": false
}
```

Credentials never go in project files. The SDK reads them at runtime from the platform's
secret store, so the setup never needs to open or copy a credentials file.

## Lint rules

- `src/` uses ES modules.
- No hard-coded hostnames outside `corewave.config.json` and `.npmrc`.
