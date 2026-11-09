// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#ifdef _WIN32
#include <windows.h>
#include <userenv.h>
#include <sddl.h>
#include <bcrypt.h>
#include <filesystem>
#include <string>
#include <vector>
#include <memory>
#include <stdexcept>

namespace plezy::retro {
class WindowsSandbox {
  PSID sid_ = nullptr;
  PSECURITY_DESCRIPTOR security_ = nullptr;
  HANDLE lease_ = INVALID_HANDLE_VALUE;
  std::filesystem::path root_;
  static void Require(bool value) { if (!value) throw std::runtime_error("Could not prepare emulator AppContainer"); }
  static void Remove(const std::filesystem::path& path) noexcept {
    const auto flags = GetFileAttributesW(path.c_str());
    if (flags == INVALID_FILE_ATTRIBUTES) return;
    if (flags & FILE_ATTRIBUTE_DIRECTORY) {
      // Never recurse into a junction or other reparse point a core created.
      if (!(flags & FILE_ATTRIBUTE_REPARSE_POINT)) {
        WIN32_FIND_DATAW entry{};
        const auto pattern = path / L"*";
        HANDLE search = FindFirstFileW(pattern.c_str(), &entry);
        if (search != INVALID_HANDLE_VALUE) {
          do { if (wcscmp(entry.cFileName,L".") && wcscmp(entry.cFileName,L"..")) Remove(path / entry.cFileName); }
          while (FindNextFileW(search, &entry));
          FindClose(search);
        }
      }
      RemoveDirectoryW(path.c_str());
    } else { SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL); DeleteFileW(path.c_str()); }
  }
  static void CleanupStale(const std::filesystem::path& temporary) noexcept {
    try {
      const std::string marker = "PLEAZYNG_ROMM_STAGE_V1\n";
      for (const auto& entry : std::filesystem::directory_iterator(temporary)) {
        const auto name = entry.path().filename().wstring();
        const std::wstring prefix = L"pleazyng-romm-";
        if (name.size() != prefix.size() + 32 || name.rfind(prefix, 0) != 0 ||
            name.find_first_not_of(L"0123456789abcdef", prefix.size()) != std::wstring::npos) continue;
        const auto flags = GetFileAttributesW(entry.path().c_str());
        if (flags == INVALID_FILE_ATTRIBUTES || !(flags & FILE_ATTRIBUTE_DIRECTORY) || (flags & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        const auto lock = entry.path() / L"session.lease";
        HANDLE file = CreateFileW(lock.c_str(), GENERIC_READ | DELETE, 0, nullptr, OPEN_EXISTING,
          FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        // A live parent holds a non-delete-sharing lease. Never touch its stage.
        if (file == INVALID_HANDLE_VALUE) continue;
        BY_HANDLE_FILE_INFORMATION info{}; char bytes[64]{}; DWORD read = 0;
        const bool owned = GetFileInformationByHandle(file, &info) &&
          !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
          !info.nFileSizeHigh && info.nFileSizeLow == marker.size() &&
          ReadFile(file, bytes, sizeof(bytes), &read, nullptr) &&
          read == marker.size() && std::string(bytes, read) == marker;
        if (owned) Remove(entry.path());  // The open lease deliberately survives this traversal.
        CloseHandle(file);
        if (owned) { DeleteFileW(lock.c_str()); RemoveDirectoryW(entry.path().c_str()); }
      }
    } catch (...) { /* A cleanup failure never authorizes broader deletion. */ }
  }
  void Copy(const std::filesystem::path& source, const std::filesystem::path& target, uintmax_t maximum) {
    Require(std::filesystem::is_regular_file(source) && !std::filesystem::is_symlink(source));
    Require(std::filesystem::file_size(source) <= maximum);
    Require(CopyFileW(source.c_str(), target.c_str(), TRUE) != 0);
    // Do not rely on CopyFile's OS-version-specific security propagation.
    Require(SetFileSecurityW(target.c_str(), DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION |
      LABEL_SECURITY_INFORMATION, security_) != 0);
  }
 public:
  std::filesystem::path helper, core, rom, system, saves;
  explicit WindowsSandbox(const std::filesystem::path& helperSource, const std::filesystem::path& coreSource,
                          const std::string& romSource, const std::string& systemSource) {
    try {
      constexpr auto profile = L"Pleazyng.Romm.Core";
      auto result = CreateAppContainerProfile(profile, L"Pleazyng emulator", L"Isolated bundled software cores", nullptr, 0, &sid_);
      if (result == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)) result = DeriveAppContainerSidFromAppContainerName(profile, &sid_);
      Require(SUCCEEDED(result) && sid_);
      wchar_t temporary[32768]; const auto count = GetTempPathW(32768, temporary);
      Require(count && count < 32768);
      CleanupStale(temporary);
      uint8_t random[16]; Require(BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0);
      std::wstring name = L"pleazyng-romm-";
      for (auto byte : random) { name += L"0123456789abcdef"[byte >> 4]; name += L"0123456789abcdef"[byte & 15]; }
      root_ = std::filesystem::path(temporary) / name;
      HANDLE token = nullptr; Require(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) != 0);
      DWORD size = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &size);
      std::vector<uint8_t> info(size);
      const bool got = GetTokenInformation(token, TokenUser, info.data(), size, &size) != 0;
      CloseHandle(token); Require(got);
      LPWSTR userText = nullptr, appText = nullptr;
      Require(ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(info.data())->User.Sid, &userText) != 0);
      if (!ConvertSidToStringSidW(sid_, &appText)) { LocalFree(userText); Require(false); }
      const std::wstring sddl = L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + std::wstring(userText) +
        L")(A;OICI;0x1200a9;;;" + std::wstring(appText) + L")S:(ML;OICI;NW;;;LW)";
      LocalFree(userText); LocalFree(appText);
      Require(ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &security_, nullptr) != 0);
      SECURITY_ATTRIBUTES attributes{sizeof(attributes), security_, FALSE};
      const bool created = CreateDirectoryW(root_.c_str(), &attributes) != 0;
      Require(created);
      lease_ = CreateFileW((root_ / L"session.lease").c_str(), GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
      Require(lease_ != INVALID_HANDLE_VALUE);
      const std::string marker = "PLEAZYNG_ROMM_STAGE_V1\n"; DWORD written = 0;
      Require(WriteFile(lease_, marker.data(), DWORD(marker.size()), &written, nullptr) && written == marker.size());
      helper = root_ / L"plezy_retro_worker.exe"; core = root_ / coreSource.filename();
      Copy(helperSource, helper, 64 * 1024 * 1024); Copy(coreSource, core, 256 * 1024 * 1024);
      // App-local CRT files are the only additional executables staged. System
      // DLLs remain governed by AppContainer's normal OS-resource policy.
      for (const auto& entry : std::filesystem::directory_iterator(helperSource.parent_path())) {
        const auto name = entry.path().filename().wstring();
        if (entry.path().extension() == L".dll" && (name.rfind(L"vcruntime140", 0) == 0 || name.rfind(L"msvcp140", 0) == 0))
          Copy(entry.path(), root_ / entry.path().filename(), 32 * 1024 * 1024);
      }
      system = root_ / L"system"; saves = root_ / L"saves";
      Require(CreateDirectoryW(system.c_str(), nullptr) && CreateDirectoryW(saves.c_str(), nullptr));
      if (!romSource.empty()) {
        const auto source = std::filesystem::u8path(romSource); rom = root_ / (L"game" + source.extension().wstring());
        Copy(source, rom, 128 * 1024 * 1024);
      }
      if (!systemSource.empty()) {
        const auto source = std::filesystem::u8path(systemSource);
        size_t files = 0; uintmax_t bytes = 0;
        for (const auto& entry : std::filesystem::recursive_directory_iterator(source)) {
          Require(++files <= 512 && !entry.is_symlink());
          const auto target = system / entry.path().lexically_relative(source);
          if (entry.is_directory()) Require(CreateDirectoryW(target.c_str(), nullptr) != 0);
          else {
            const auto size = entry.file_size(); bytes += size; Require(bytes <= 256 * 1024 * 1024);
            Copy(entry.path(), target, 128 * 1024 * 1024);
          }
        }
      }
    } catch (...) {
      if (lease_ != INVALID_HANDLE_VALUE) CloseHandle(lease_);
      lease_ = INVALID_HANDLE_VALUE;
      Remove(root_); if (sid_) FreeSid(sid_); if (security_) LocalFree(security_); sid_ = nullptr; security_ = nullptr; throw;
    }
  }
  ~WindowsSandbox() { if (lease_ != INVALID_HANDLE_VALUE) CloseHandle(lease_); Remove(root_); if (sid_) FreeSid(sid_); if (security_) LocalFree(security_); }
  PSID Sid() const { return sid_; }
};
}  // namespace plezy::retro
#endif
