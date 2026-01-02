# MoonMod CLI — Lightweight Lua package installer

MoonMod CLI is a single-file Lua utility (MoonModCLI.lua) that installs, updates, and removes small MoonMod packages distributed as ZIP archives and described with tiny text descriptors. It's designed to be minimal, portable, and easy to audit — ideal for quick mod installs, automation, or embedding in lightweight workflows.

- Single-file CLI: MoonModCLI.lua
- Cross-platform: works on Unix and Windows (uses LuaFileSystem for paths)
- Minimal dependencies: LuaSocket (HTTP), LuaZip (ZIP handling), LuaFileSystem (filesystem)
- Descriptor-driven: packages are described with small `.mnmd.txt` descriptor files

Why MoonMod?
- Extremely small and auditable codebase — one file to read and reason about.
- Simple descriptor format makes packaging and sharing trivial.
- Recursive dependency support so packages can reference other descriptors.

Quick usage
- Install a package from a descriptor URL or local path:
  moonmod install https://example.com/MyPackage.mnmd.txt
- Remove a package (safe: prevents removal when other installed packages depend on it):
  moonmod remove MyPackage
- Update a package (re-download and reinstall from the saved descriptor):
  moonmod update MyPackage
- Update all installed packages:
  moonmod update all

Descriptor format (MyPackage.mnmd.txt)
1. [MoonMod Package]                -- exact header
2. https://example.com/MyPackage.zip -- ZIP URL (line 2)
3. depA.mnmd.txt;https://.../depB.mnmd.txt -- semicolon-separated deps (optional)
4. "Welcome message to print after install" -- quoted message (optional)
5. 1.0.0                             -- version (stored, not enforced)

Where packages install
- Packages are installed under your home directory in `.MoonMod/<PackageName>/`
- Each package folder contains the unpacked ZIP contents plus the original `<PackageName>.mnmd.txt` descriptor

Dependencies
- Requires Lua with:
  - LuaSocket (socket.http, ltn12)
  - LuaZip (zip)
  - LuaFileSystem (lfs)

Example descriptor (minimal)
```
[MoonMod Package]
https://example.com/SimpleMod.zip

"SimpleMod installed!"
1.0
```

Get started
1. Ensure Lua and the required modules are installed.
2. Place MoonModCLI.lua on your PATH or run it directly with `lua MoonModCLI.lua ...`
3. Create or download a `.mnmd.txt` descriptor and run `moonmod install <descriptor>`

License & Auditing
- MoonModCLI.lua intentionally keeps logic compact and readable — review the single-file script before running if you prefer to audit downloads and install behavior.

See MoonModCLI.lua for implementation details and exact behavior:
https://github.com/Rudycon55555/MoonMod/blob/469c3d7b56cda19bd564fe8f66a98a245aff593e/MoonModCLI.lua
