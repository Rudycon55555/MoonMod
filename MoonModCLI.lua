-- MoonMod CLI (single file)
-- Dependencies: LuaSocket (socket.http, ltn12) and LuaZip (zip)
-- Provides commands:
--   moonmod install <descriptor_url_or_path>
--   moonmod remove <package_name>
--   moonmod update <package_name>
--   moonmod update all
--
-- Notes:
-- - Descriptor files are named <package_name>.mnmd.txt and must start with:
--     [MoonMod Package]
-- - Line 2: ZIP URL
-- - Line 3: dependencies (semicolon-separated URLs or filepaths; no spaces required)
-- - Line 4: a quoted message to print (e.g. "Hello world")
-- - Line 5: version (ignored by logic except stored)
--
-- This script uses only standard Lua + LuaSocket + LuaZip.

local http = require("socket.http")
local ltn12 = require("ltn12")
local zip = require("zip")

-- Utilities -----------------------------------------------------------------

local function getenv_any(...)
    for i = 1, select("#", ...) do
        local v = os.getenv(select(i, ...))
        if v and v ~= "" then return v end
    end
    return nil
end

local function get_home()
    local home = getenv_any("HOME", "USERPROFILE")
    assert(home and #home > 0, "MoonMod: HOME or USERPROFILE environment variable not set")
    return home
end

local function is_url(s)
    return type(s) == "string" and s:match("^https?://")
end

local function basename(path)
    return path:match("([^/\\]+)$")
end

local function strip_suffix(name, suffix)
    if name:sub(-#suffix) == suffix then
        return name:sub(1, -#suffix-1)
    end
    return name
end

local function shell_escape(s)
    -- simple quoting for shell commands
    if package.config:sub(1,1) == "\\" then
        -- Windows: wrap in double quotes, double internal quotes
        s = s:gsub('"', '\\"')
        return '"' .. s .. '"'
    else
        -- Unix: single-quote and escape single quotes
        if s:find("'") then
            s = s:gsub("'", "'\\''")
        end
        return "'" .. s .. "'"
    end
end

-- Filesystem helpers (use os.execute / io.popen where needed) ----------------

local function mkdir_p(path)
    if package.config:sub(1,1) == "\\" then
        -- Windows
        local cmd = "mkdir " .. shell_escape(path)
        os.execute(cmd)
    else
        local cmd = "mkdir -p " .. shell_escape(path)
        os.execute(cmd)
    end
end

local function remove_dir_recursive(path)
    if package.config:sub(1,1) == "\\" then
        -- Windows rmdir /s /q
        local cmd = 'rmdir /s /q ' .. shell_escape(path)
        os.execute(cmd)
    else
        local cmd = 'rm -rf ' .. shell_escape(path)
        os.execute(cmd)
    end
end

local function list_dir(path)
    local entries = {}
    if package.config:sub(1,1) == "\\" then
        -- Windows: use dir /b
        local p = io.popen('dir /b ' .. shell_escape(path) .. " 2>nul")
        if not p then return entries end
        for line in p:lines() do table.insert(entries, line) end
        p:close()
    else
        local p = io.popen('ls -1 ' .. shell_escape(path) .. ' 2>/dev/null')
        if not p then return entries end
        for line in p:lines() do table.insert(entries, line) end
        p:close()
    end
    return entries
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local dir = path:match("^(.*)[/\\][^/\\]+$")
    if dir and not file_exists(dir) then
        mkdir_p(dir)
    end
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(data)
    f:close()
    return true
end

-- HTTP GET ------------------------------------------------------------------

local function http_get(url)
    local t = {}
    local res, code, headers, status = http.request{
        url = url,
        sink = ltn12.sink.table(t)
    }
    if not res then
        return nil, ("HTTP request failed for %s (code=%s)"):format(url, tostring(code))
    end
    if code ~= 200 then
        return nil, ("HTTP GET %s returned status %s"):format(url, tostring(code))
    end
    return table.concat(t)
end

-- ZIP extraction using LuaZip -----------------------------------------------

local function write_temp_file(data)
    local tmpname = os.tmpname()
    -- On some systems os.tmpname returns a path without extension; safe to use
    local ok, err = write_file(tmpname, data)
    if not ok then return nil, err end
    return tmpname
end

local function unzip_bytes_to_dir(zip_bytes, target_dir)
    local tmpzip, err = write_temp_file(zip_bytes)
    if not tmpzip then return nil, err end

    local z, zerr = zip.open(tmpzip)
    if not z then
        os.remove(tmpzip)
        return nil, "zip.open failed: " .. tostring(zerr)
    end

    for i = 1, z:nfiles() do
        local stat = z:stat(i)
        local name = stat.name
        -- Normalize path separators to system
        local outpath = target_dir .. (target_dir:sub(-1) == "/" or target_dir:sub(-1) == "\\" and "" or "/") .. name
        local dir = outpath:match("^(.*)[/\\][^/\\]+$")
        if dir then mkdir_p(dir) end

        -- If entry is a directory (name ends with /), ensure dir exists
        if name:sub(-1) == "/" or name:sub(-1) == "\\" then
            mkdir_p(outpath)
        else
            local f = z:open(name)
            if f then
                local content = f:read("*a")
                f:close()
                write_file(outpath, content)
            end
        end
    end

    z:close()
    os.remove(tmpzip)
    return true
end

-- Descriptor parsing --------------------------------------------------------

local function parse_descriptor(text)
    if not text then return nil, "empty descriptor" end
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do table.insert(lines, line) end
    if #lines < 1 then return nil, "descriptor too short" end
    if lines[1] ~= "[MoonMod Package]" then
        return nil, "descriptor missing [MoonMod Package] header"
    end
    local zip_url = lines[2] or ""
    local deps_line = lines[3] or ""
    local deps = {}
    if deps_line ~= "" then
        for dep in deps_line:gmatch("([^;]+)") do
            dep = dep:gsub("^%s+", ""):gsub("%s+$", "")
            if dep ~= "" then table.insert(deps, dep) end
        end
    end
    local message = ""
    if lines[4] then
        local q = lines[4]:match('"([^"]-)"')
        if q then message = q end
    end
    local version = lines[5] or ""
    return {
        zip_url = zip_url,
        deps = deps,
        message = message,
        version = version
    }
end

-- Core operations -----------------------------------------------------------

local function get_root_dir()
    local home = get_home()
    local root = home .. (package.config:sub(1,1) == "\\" and "\\.MoonMod" or "/.MoonMod")
    return root
end

local function infer_pkg_name_from_descriptor_path(path_or_url)
    local name = basename(path_or_url)
    if not name then return nil end
    name = strip_suffix(name, ".mnmd.txt")
    return name
end

local function install_descriptor(descriptor_ref, installed)
    installed = installed or {}
    local descriptor_text, err

    if is_url(descriptor_ref) then
        descriptor_text, err = http_get(descriptor_ref)
        if not descriptor_text then return nil, err end
    else
        descriptor_text, err = read_file(descriptor_ref)
        if not descriptor_text then return nil, "Cannot read descriptor file: " .. tostring(err) end
    end

    local desc, perr = parse_descriptor(descriptor_text)
    if not desc then return nil, perr end

    local pkg_name = infer_pkg_name_from_descriptor_path(descriptor_ref)
    if not pkg_name then return nil, "Cannot infer package name from descriptor reference: " .. tostring(descriptor_ref) end

    if installed[pkg_name] then
        return true -- already processed in this run
    end
    installed[pkg_name] = true

    if not desc.zip_url or desc.zip_url == "" then
        return nil, "Descriptor missing ZIP URL (line 2)"
    end

    -- Fetch ZIP
    local zip_bytes, zerr = http_get(desc.zip_url)
    if not zip_bytes then return nil, "Failed to fetch ZIP: " .. tostring(zerr)
    end

    -- Prepare install dir
    local root = get_root_dir()
    mkdir_p(root)
    local pkg_dir = root .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name

    -- If package dir exists, remove it first (fresh install)
    if file_exists(pkg_dir) then
        remove_dir_recursive(pkg_dir)
    end
    mkdir_p(pkg_dir)

    -- Unzip into pkg_dir
    local ok, uerr = unzip_bytes_to_dir(zip_bytes, pkg_dir)
    if not ok then return nil, "Unzip failed: " .. tostring(uerr) end

    -- Save descriptor inside package dir
    local descriptor_filename = pkg_name .. ".mnmd.txt"
    local saved, serr = write_file(pkg_dir .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. descriptor_filename, descriptor_text)
    if not saved then return nil, "Failed to save descriptor: " .. tostring(serr) end

    -- Install dependencies recursively
    for _, dep in ipairs(desc.deps) do
        local dep_ref = dep
        -- If dependency is a relative path (not URL and not absolute), treat relative to descriptor_ref if descriptor_ref is a file path
        if not is_url(dep_ref) and not dep_ref:match("^[/\\]") and not is_url(descriptor_ref) then
            -- descriptor_ref may be a local path; compute its directory
            local base = descriptor_ref:match("^(.*)[/\\][^/\\]+$") or "."
            dep_ref = base .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. dep_ref
        end
        local res, rerr = install_descriptor(dep_ref, installed)
        if not res then return nil, ("Failed to install dependency %s: %s"):format(dep_ref, tostring(rerr)) end
    end

    -- Print message (line 4 quoted text)
    if desc.message and desc.message ~= "" then
        print(desc.message)
    end

    return true
end

local function find_all_installed_packages()
    local root = get_root_dir()
    if not file_exists(root) then return {} end
    local entries = list_dir(root)
    local pkgs = {}
    for _, e in ipairs(entries) do
        -- Only directories are packages; we assume entries are package folder names
        table.insert(pkgs, e)
    end
    return pkgs
end

local function read_installed_descriptor(pkg_name)
    local root = get_root_dir()
    local desc_path = root .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name .. ".mnmd.txt"
    local text = read_file(desc_path)
    if not text then return nil, "Descriptor not found for package " .. pkg_name end
    local desc, err = parse_descriptor(text)
    if not desc then return nil, err end
    return desc
end

local function remove_package(pkg_name)
    -- Check dependencies: scan all installed descriptors for references to this package
    local pkgs = find_all_installed_packages()
    for _, other in ipairs(pkgs) do
        if other ~= pkg_name then
            local desc, err = read_installed_descriptor(other)
            if desc then
                for _, dep in ipairs(desc.deps) do
                    -- If dependency is a URL ending with <pkg_name>.mnmd.txt or a local filename matching
                    local dep_basename = basename(dep)
                    if dep_basename and strip_suffix(dep_basename, ".mnmd.txt") == pkg_name then
                        return nil, ("Cannot remove '%s': package '%s' depends on it"):format(pkg_name, other)
                    end
                end
            end
        end
    end

    -- Remove directory
    local root = get_root_dir()
    local pkg_dir = root .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name
    if not file_exists(pkg_dir) then
        return nil, "Package not installed: " .. pkg_name
    end
    remove_dir_recursive(pkg_dir)
    return true
end

local function update_package(pkg_name)
    local desc, err = read_installed_descriptor(pkg_name)
    if not desc then return nil, err end
    -- Reinstall from descriptor's zip_url
    -- Create a temporary descriptor file content to pass to install_descriptor
    -- We'll create a temp descriptor path in system temp and write the descriptor content
    local root = get_root_dir()
    local installed_desc_path = root .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name .. ".mnmd.txt"
    -- install_descriptor can accept a local path; reuse the saved descriptor
    local ok, ierr = install_descriptor(installed_desc_path, {})
    if not ok then return nil, ierr end
    return true
end

local function update_all()
    local pkgs = find_all_installed_packages()
    for _, p in ipairs(pkgs) do
        io.write(("Updating %s ... "):format(p))
        local ok, err = update_package(p)
        if ok then print("done") else print("failed: " .. tostring(err)) end
    end
    return true
end

-- CLI ----------------------------------------------------------------------

local function usage()
    print("MoonMod CLI")
    print("Usage:")
    print("  moonmod install <descriptor_url_or_path>")
    print("  moonmod remove <package_name>")
    print("  moonmod update <package_name>")
    print("  moonmod update all")
end

local args = {...}
local cmd = args[1]

if not cmd then
    usage()
    os.exit(1)
end

if cmd == "install" then
    local ref = args[2]
    if not ref then
        print("install requires a descriptor URL or filepath")
        os.exit(1)
    end
    local ok, err = install_descriptor(ref, {})
    if not ok then
        io.stderr:write("Install failed: " .. tostring(err) .. "\n")
        os.exit(2)
    else
        print("Installed.")
    end

elseif cmd == "remove" then
    local pkg = args[2]
    if not pkg then
        print("remove requires a package name")
        os.exit(1)
    end
    local ok, err = remove_package(pkg)
    if not ok then
        io.stderr:write("Remove failed: " .. tostring(err) .. "\n")
        os.exit(2)
    else
        print("Removed " .. pkg)
    end

elseif cmd == "update" then
    local target = args[2]
    if not target then
        print("update requires a package name or 'all'")
        os.exit(1)
    end
    if target == "all" then
        local ok, err = update_all()
        if not ok then io.stderr:write("Update all failed: " .. tostring(err) .. "\n"); os.exit(2) end
    else
        local ok, err = update_package(target)
        if not ok then io.stderr:write("Update failed: " .. tostring(err) .. "\n"); os.exit(2) end
        print("Updated " .. target)
    end

else
    usage()
    os.exit(1)
end
