-- MoonMod CLI (single file)
-- Dependencies: LuaSocket (socket.http, ltn12), LuaZip (zip), LuaFileSystem (lfs)
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
-- This script uses LuaSocket, LuaZip and LuaFileSystem.

local http = require("socket.http")
local ltn12 = require("ltn12")
local zip = require("zip")
local lfs = require("lfs")

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
    -- simple quoting for shell commands (still used in small places, kept for compatibility)
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

-- Filesystem helpers (use LuaFileSystem for cross-platform safety) ---------

local function is_windows()
    return package.config:sub(1,1) == "\\"
end

local function join_separators()
    return is_windows() and "\\" or "/"
end

local function file_exists(path)
    if not path or path == "" then return false end
    local ok, err = lfs.attributes(path)
    return ok ~= nil
end

-- Create directories recursively using lfs.mkdir
local function mkdir_p(path)
    if not path or path == "" then return true end
    -- If already exists and is a directory, we're done
    local attr = lfs.attributes(path)
    if attr and attr.mode == "directory" then return true end

    -- Handle platform-specific absolute prefixes
    local prefix = ""
    local rest = path

    if is_windows() then
        -- Drive letter like C:\ or UNC \\server\share
        local drive = rest:match("^%a:\\")
        if drive then
            prefix = drive
            rest = rest:sub(#drive + 1)
        elseif rest:sub(1,2) == "\\\\" then
            -- UNC path: keep leading double slashes as prefix
            prefix = "\\\\"
            rest = rest:sub(3)
        end
    else
        if rest:sub(1,1) == "/" then
            prefix = "/"
            rest = rest:sub(2)
        end
    end

    local sep = join_separators()
    local cur = prefix
    for part in rest:gmatch("[^/\\]+") do
        if cur == "" or cur:sub(-1) == "/" or cur:sub(-1) == "\\" then
            cur = cur .. part
        else
            cur = cur .. sep .. part
        end
        local a = lfs.attributes(cur)
        if not a then
            local ok, err = lfs.mkdir(cur)
            if not ok then
                return nil, ("mkdir failed for %s: %s"):format(cur, tostring(err))
            end
        elseif a.mode ~= "directory" then
            return nil, ("path exists and is not a directory: %s"):format(cur)
        end
    end
    return true
end

-- Remove directory recursively using lfs
local function remove_dir_recursive(path)
    if not path or path == "" then
        return nil, "invalid path"
    end
    local attr = lfs.attributes(path)
    if not attr then
        return nil, ("path does not exist: %s"):format(path)
    end
    local mode = attr.mode
    if mode == "file" or mode == "link" then
        local ok, err = os.remove(path)
        if not ok then return nil, ("failed to remove file %s: %s"):format(path, tostring(err)) end
        return true
    elseif mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local entrypath = path .. (path:sub(-1) == "/" or path:sub(-1) == "\\" and "" or "/")
                -- ensure correct separator
                local sep = join_separators()
                if entrypath:sub(-1) ~= "/" and entrypath:sub(-1) ~= "\\" then
                    entrypath = path .. sep
                else
                    entrypath = path
                end
                entrypath = entrypath .. entry
                local eattr = lfs.attributes(entrypath)
                if eattr and eattr.mode == "directory" then
                    local ok, err = remove_dir_recursive(entrypath)
                    if not ok then return nil, err end
                else
                    local ok, err = os.remove(entrypath)
                    if not ok then return nil, ("failed to remove file %s: %s"):format(entrypath, tostring(err)) end
                end
            end
        end
        local ok, err = lfs.rmdir(path)
        if not ok then return nil, ("failed to remove directory %s: %s"):format(path, tostring(err)) end
        return true
    else
        return nil, ("unsupported file type for removal: %s"):format(tostring(mode))
    end
end

-- List directory entries (non-recursive)
local function list_dir(path)
    local entries = {}
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "directory" then
        return entries
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            table.insert(entries, entry)
        end
    end
    return entries
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
        local ok, err = mkdir_p(dir)
        if not ok then return nil, err end
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
        if dir then
            local ok, derr = mkdir_p(dir)
            if not ok then
                z:close()
                os.remove(tmpzip)
                return nil, ("failed to create directory %s: %s"):format(dir, tostring(derr))
            end
        end

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
    local ok, merr = mkdir_p(root)
    if not ok then return nil, ("Failed to create root dir %s: %s"):format(root, tostring(merr)) end
    local pkg_dir = root .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name

    -- If package dir exists, remove it first (fresh install)
    if file_exists(pkg_dir) then
        local ok, rerr = remove_dir_recursive(pkg_dir)
        if not ok then return nil, ("Failed to remove existing package dir: %s"):format(tostring(rerr)) end
    end
    local ok2, merr2 = mkdir_p(pkg_dir)
    if not ok2 then return nil, ("Failed to create package dir %s: %s"):format(pkg_dir, tostring(merr2)) end

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
    local ok, err = remove_dir_recursive(pkg_dir)
    if not ok then return nil, err end
    return true
end

local function update_package(pkg_name)
    local desc, err = read_installed_descriptor(pkg_name)
    if not desc then return nil, err end
    -- Reinstall from descriptor's zip_url
    local root = get_root_dir()
    local installed_desc_path = root .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. pkg_name .. ".mnmd.txt"
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
