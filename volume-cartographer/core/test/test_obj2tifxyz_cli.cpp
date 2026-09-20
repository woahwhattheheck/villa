// Real-data CLI regression for ScrollPrize/villa#1320.
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "vc_test.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#ifdef _WIN32
TEST_CASE("obj2tifxyz CLI regression is POSIX-only") {}
#else

#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace {

std::string sh(const std::string& value)
{
    std::string quoted = "'";
    for (char c : value) {
        if (c == '\'') quoted += "'\\''";
        else quoted += c;
    }
    return quoted + "'";
}

int run_cli(const std::string& binary,
            const std::vector<std::string>& args,
            const fs::path& log)
{
    std::string cmd = sh(binary);
    for (const auto& arg : args) cmd += " " + sh(arg);
    cmd += " >" + sh(log.string()) + " 2>&1";
    const int rc = std::system(cmd.c_str());
    REQUIRE(rc != -1);
    return WIFEXITED(rc) ? WEXITSTATUS(rc) : -2;
}

std::string read_all(const fs::path& path)
{
    std::ifstream in(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), {});
}

struct TempDir {
    fs::path path;

    TempDir()
    {
        path = fs::temp_directory_path()
             / ("vc_obj2tifxyz_cli_" + std::to_string(::getpid()));
        fs::remove_all(path);
        fs::create_directories(path);
    }

    ~TempDir()
    {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

}  // namespace

TEST_CASE("normalized PHerc segment never reports an empty raster as success")
{
    TempDir tmp;
    const fs::path fixture =
        fs::path(VC_TEST_FIXTURES_DIR) / "segments" / "20241113070770";
    REQUIRE(fs::is_directory(fixture));

    // This checked-in PHerc 0172 segment is also used by
    // test_quadsurface_fixtures. Convert the real tifxyz surface to the
    // normalized-UV form reported in #1320.
    const fs::path obj = tmp.path / "normalized.obj";
    const fs::path to_obj_log = tmp.path / "to_obj.log";
    REQUIRE(run_cli(
                VC_TIFXYZ2OBJ_BIN,
                {fixture.string(), obj.string(), "--normalize-uv"},
                to_obj_log)
            == 0);
    REQUIRE(fs::is_regular_file(obj));

    // The default stretch factor creates too sparse a UV grid for this real
    // surface. It must fail before save rather than emit an all-sentinel
    // tifxyz directory with a success exit status.
    const fs::path rejected = tmp.path / "default";
    const fs::path rejected_log = tmp.path / "default.log";
    CHECK(run_cli(
              VC_OBJ2TIFXYZ_BIN,
              {obj.string(), rejected.string()},
              rejected_log)
          == 1);
    const std::string failure = read_all(rejected_log);
    CHECK(failure.find("no valid grid points were rasterized")
          != std::string::npos);
    CHECK_FALSE(fs::exists(rejected / "x.tif"));
    CHECK_FALSE(fs::exists(rejected / "y.tif"));
    CHECK_FALSE(fs::exists(rejected / "z.tif"));

    // Existing real-data fixtures document stretch_factor=128 for these
    // segments. Keep that working as the positive control.
    const fs::path accepted = tmp.path / "scaled";
    const fs::path accepted_log = tmp.path / "scaled.log";
    CHECK(run_cli(
              VC_OBJ2TIFXYZ_BIN,
              {obj.string(), accepted.string(), "128"},
              accepted_log)
          == 0);
    CHECK(fs::is_regular_file(accepted / "x.tif"));
    CHECK(fs::is_regular_file(accepted / "y.tif"));
    CHECK(fs::is_regular_file(accepted / "z.tif"));
}

#endif
