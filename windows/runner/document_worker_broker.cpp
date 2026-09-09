#include "document_worker_broker.h"
#include "document_worker_manifest_digest.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <userenv.h>

#include <array>
#include <algorithm>
#include <atomic>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Result = std::unique_ptr<flutter::MethodResult<Value>>;
constexpr size_t kMaxRequest = 108 + 10 * 1024 * 1024;
constexpr size_t kMaxResponse = 1024 * 1024;

class Handle {
 public:
  Handle(HANDLE value = nullptr) : value_(value) {}
  ~Handle() { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value_(other.value_) { other.value_ = nullptr; }
  HANDLE get() const { return value_; }
  HANDLE release() { HANDLE value = value_; value_ = nullptr; return value; }
  void reset(HANDLE value = nullptr) {
    if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
    value_ = value;
  }
 private:
  HANDLE value_;
};

struct FileIdentity {
  DWORD volume;
  DWORD index_high;
  DWORD index_low;
};

bool ReadIdentity(HANDLE file, FileIdentity* identity) {
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(file, &info)) return false;
  *identity = {info.dwVolumeSerialNumber, info.nFileIndexHigh,
               info.nFileIndexLow};
  return true;
}

bool SameIdentity(const FileIdentity& left, const FileIdentity& right) {
  return left.volume == right.volume && left.index_high == right.index_high &&
         left.index_low == right.index_low;
}

std::wstring BundleDirectory() {
  std::array<wchar_t, 32768> path{};
  DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                    static_cast<DWORD>(path.size()));
  if (!length || length == static_cast<DWORD>(path.size())) return {};
  return std::filesystem::path(path.data()).parent_path().wstring();
}

Handle OpenOrdinaryDirectFile(const std::filesystem::path& root,
                              const std::filesystem::path& path) {
  if (path.parent_path() != root) return {};
  Handle file(CreateFileW(path.c_str(), GENERIC_READ,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) return {};
  FILE_ATTRIBUTE_TAG_INFO tag{};
  if (!GetFileInformationByHandleEx(file.get(), FileAttributeTagInfo,
      &tag, sizeof(tag)) || (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      (tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) return {};
  return file;
}

bool PathUnder(const std::filesystem::path& path,
               const std::filesystem::path& parent) {
  if (parent.empty()) return false;
  const auto path_text = path.lexically_normal().wstring();
  auto parent_text = parent.lexically_normal().wstring();
  if (parent_text.back() != L'\\') parent_text.push_back(L'\\');
  return path_text.size() > parent_text.size() &&
      _wcsnicmp(path_text.c_str(), parent_text.c_str(), parent_text.size()) == 0;
}

bool NoReparseAncestors(std::filesystem::path path) {
  while (!path.empty()) {
    Handle entry(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    FILE_ATTRIBUTE_TAG_INFO tag{};
    if (entry.get() == INVALID_HANDLE_VALUE ||
        !GetFileInformationByHandleEx(entry.get(), FileAttributeTagInfo,
            &tag, sizeof(tag)) || (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
      return false;
    const auto parent = path.parent_path();
    if (parent == path) break;
    path = parent;
  }
  return true;
}

bool TrustedBundleProvenance(const std::filesystem::path& bundle) {
  if (!NoReparseAncestors(bundle)) return false;
  Handle directory(CreateFileW(bundle.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  FILE_ATTRIBUTE_TAG_INFO tag{};
  if (directory.get() == INVALID_HANDLE_VALUE ||
      !GetFileInformationByHandleEx(directory.get(), FileAttributeTagInfo,
          &tag, sizeof(tag)) || (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      !(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) return false;
  std::array<wchar_t, 32768> program_files{};
  const DWORD length = GetEnvironmentVariableW(
      L"ProgramW6432", program_files.data(), static_cast<DWORD>(program_files.size()));
  if (length && length < program_files.size() &&
      PathUnder(bundle, program_files.data())) return true;

  HANDLE token_raw = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token_raw)) return false;
  Handle token(token_raw);
  TOKEN_ELEVATION elevation{};
  DWORD returned = 0;
  if (!GetTokenInformation(token.get(), TokenElevation, &elevation,
                           sizeof(elevation), &returned) || elevation.TokenIsElevated)
    return false;
  GetTokenInformation(token.get(), TokenUser, nullptr, 0, &returned);
  std::vector<uint8_t> user_buffer(returned);
  if (!returned || !GetTokenInformation(token.get(), TokenUser,
          user_buffer.data(), returned, &returned)) return false;
  PSID owner = nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (GetNamedSecurityInfoW(const_cast<wchar_t*>(bundle.c_str()), SE_FILE_OBJECT,
          OWNER_SECURITY_INFORMATION, &owner, nullptr, nullptr, nullptr,
          &descriptor) != ERROR_SUCCESS) return false;
  const auto* user = reinterpret_cast<TOKEN_USER*>(user_buffer.data());
  const bool same_user = EqualSid(owner, user->User.Sid) != FALSE;
  LocalFree(descriptor);
  return same_user;
}

std::string Sha256(HANDLE file) {
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN)) return {};
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0, returned = 0;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
          reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size), &returned, 0) < 0) {
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    return {};
  }
  std::vector<uint8_t> object(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(),
                       static_cast<ULONG>(object.size()),
                       nullptr, 0, 0) < 0) {
    BCryptCloseAlgorithmProvider(algorithm, 0); return {};
  }
  std::array<uint8_t, 65536> buffer{};
  for (;;) {
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &read, nullptr) ||
        (read && BCryptHashData(hash, buffer.data(), read, 0) < 0)) {
      BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0); return {};
    }
    if (!read) break;
  }
  std::array<uint8_t, 32> digest{};
  const bool ok = BCryptFinishHash(hash, digest.data(),
                                   static_cast<ULONG>(digest.size()), 0) >= 0;
  BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!ok) return {};
  static constexpr char hex[] = "0123456789abcdef";
  std::string result(64, '0');
  for (size_t i = 0; i < digest.size(); ++i) {
    result[i * 2] = hex[digest[i] >> 4]; result[i * 2 + 1] = hex[digest[i] & 15];
  }
  return result;
}

bool VerifyPackage(std::filesystem::path* helper, std::vector<Handle>* files,
                   FileIdentity* helper_identity) {
  const std::filesystem::path root = BundleDirectory();
  if (root.empty() || !TrustedBundleProvenance(root)) return false;
  for (const auto& entry : kDocumentWorkerManifest) {
    const auto path = root / entry.first;
    Handle file = OpenOrdinaryDirectFile(root, path);
    if (!file.get() || Sha256(file.get()) != entry.second) return false;
    if (path.filename() == L"document_worker.exe" &&
        !ReadIdentity(file.get(), helper_identity)) return false;
    files->push_back(std::move(file));
  }
  *helper = root / L"document_worker.exe";
  return files->size() == kDocumentWorkerManifest.size();
}

class Broker {
 public:
  explicit Broker(flutter::BinaryMessenger* messenger)
      : channel_(messenger, "mobilka/document_worker",
                 &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler([this](const auto& call, Result result) {
      if (call.method_name() == "capabilities") return Capabilities(std::move(result));
      if (call.method_name() == "run") return Run(call.arguments(), std::move(result));
      if (call.method_name() == "terminate") return Terminate(std::move(result));
      result->NotImplemented();
    });
  }
  ~Broker() { Stop(); }

  void Stop() {
    HANDLE job = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_); job = job_.get();
    }
    if (job) TerminateJobObject(job, 1);
    if (thread_.joinable()) thread_.join();
  }

 private:
  void Capabilities(Result result) {
    std::filesystem::path helper;
    std::vector<Handle> files;
    FileIdentity identity{};
    const bool ready = VerifyPackage(&helper, &files, &identity) &&
                       AppContainerAvailable();
    flutter::EncodableList capabilities;
    if (ready) for (const char* name : {"isolatedProcess", "offline", "immutableInput",
        "boundedOutput", "osManagedMemoryIsolation", "wallDeadline",
        "workerInvalidatedAfterDeadline"}) capabilities.emplace_back(name);
    result->Success(Value(flutter::EncodableMap{{Value("version"), Value(1)},
        {Value("available"), Value(ready)}, {Value("capabilities"), Value(capabilities)}}));
  }

  bool AppContainerAvailable() {
    PSID sid = nullptr;
    HRESULT hr = DeriveAppContainerSidFromAppContainerName(
        L"mobilka.document.worker", &sid);
    if (FAILED(hr)) hr = CreateAppContainerProfile(L"mobilka.document.worker",
        L"mobilka document worker", L"mobilka document worker", nullptr, 0, &sid);
    if (sid) FreeSid(sid);
    return SUCCEEDED(hr) || hr == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
  }

  void Run(const Value* arguments, Result result) {
    const auto* bytes = arguments ? std::get_if<std::vector<uint8_t>>(arguments) : nullptr;
    if (!bytes || bytes->size() < 108 || bytes->size() > kMaxRequest) {
      result->Error("invalid_document_worker_request"); return;
    }
    std::filesystem::path helper;
    std::vector<Handle> package_files;
    FileIdentity helper_identity{};
    if (!VerifyPackage(&helper, &package_files, &helper_identity) ||
        !AppContainerAvailable()) {
      result->Error("document_worker_unavailable"); return;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (running_) { result->Error("document_worker_busy"); return; }
      running_ = true;
    }
    if (thread_.joinable()) thread_.join();
    thread_ = std::thread([this, helper, files = std::move(package_files),
                           helper_identity, request = *bytes,
                           result = std::move(result)]() mutable {
      Execute(helper, helper_identity, std::move(files), request,
              std::move(result));
      std::lock_guard<std::mutex> lock(mutex_); job_.reset(); running_ = false;
    });
  }

  void Terminate(Result result) {
    HANDLE job = nullptr;
    { std::lock_guard<std::mutex> lock(mutex_); job = job_.get(); }
    if (job) TerminateJobObject(job, 1);
    result->Success();
  }

  void Execute(const std::filesystem::path& helper,
               const FileIdentity& helper_identity,
               std::vector<Handle> package_files,
               const std::vector<uint8_t>& request, Result result) {
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    HANDLE input_read_raw = nullptr, input_write_raw = nullptr;
    HANDLE output_read_raw = nullptr, output_write_raw = nullptr;
    if (!CreatePipe(&input_read_raw, &input_write_raw, &security, 0) ||
        !CreatePipe(&output_read_raw, &output_write_raw, &security, 0)) {
      result->Error("document_worker_unavailable"); return;
    }
    Handle input_read(input_read_raw), input_write(input_write_raw),
        output_read(output_read_raw), output_write(output_write_raw);
    SetHandleInformation(input_write.get(), HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(output_read.get(), HANDLE_FLAG_INHERIT, 0);
    Handle job(CreateJobObjectW(nullptr, nullptr));
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_PROCESS_MEMORY |
        JOB_OBJECT_LIMIT_PROCESS_TIME;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    limits.ProcessMemoryLimit = 256ull * 1024 * 1024;
    limits.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 120ll * 10000000;
    if (!job.get() || !SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation,
                                               &limits, sizeof(limits))) {
      result->Error("document_worker_unavailable"); return;
    }
    PSID sid = nullptr;
    if (FAILED(DeriveAppContainerSidFromAppContainerName(L"mobilka.document.worker", &sid))) {
      result->Error("document_worker_unavailable"); return;
    }
    SECURITY_CAPABILITIES capabilities{sid, nullptr, 0, 0};
    SIZE_T attribute_size = 0;
    InitializeProcThreadAttributeList(nullptr, 2, 0, &attribute_size);
    std::vector<uint8_t> attributes(attribute_size);
    auto* list = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
    HANDLE inherited[] = {input_read.get(), output_write.get()};
    const bool attributes_ok = InitializeProcThreadAttributeList(list, 2, 0, &attribute_size) &&
        UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            inherited, sizeof(inherited), nullptr, nullptr) &&
        UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES,
            &capabilities, sizeof(capabilities), nullptr, nullptr);
    FreeSid(sid);
    if (!attributes_ok) { result->Error("document_worker_unavailable"); return; }
    STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = input_read.get();
    startup.StartupInfo.hStdOutput = output_write.get();
    startup.StartupInfo.hStdError = output_write.get();
    startup.lpAttributeList = list;
    PROCESS_INFORMATION process{};
    std::wstring command = L"\"" + helper.wstring() + L"\"";
    wchar_t empty_environment[2] = {0, 0};
    FileIdentity current_identity{};
    Handle current = OpenOrdinaryDirectFile(BundleDirectory(), helper);
    if (!current.get() || !ReadIdentity(current.get(), &current_identity) ||
        !SameIdentity(helper_identity, current_identity)) {
      DeleteProcThreadAttributeList(list);
      result->Error("document_worker_unavailable"); return;
    }
    const BOOL created = CreateProcessW(helper.c_str(), command.data(), nullptr, nullptr, TRUE,
        CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
            CREATE_NO_WINDOW,
        empty_environment, BundleDirectory().c_str(), &startup.StartupInfo, &process);
    DeleteProcThreadAttributeList(list);
    if (!created) { result->Error("document_worker_unavailable"); return; }
    Handle process_handle(process.hProcess), thread_handle(process.hThread);
    if (!AssignProcessToJobObject(job.get(), process_handle.get())) {
      TerminateProcess(process_handle.get(), 1); result->Error("document_worker_unavailable"); return;
    }
    { std::lock_guard<std::mutex> lock(mutex_); job_.reset(job.release()); }
    ResumeThread(thread_handle.get()); input_read.reset(); output_write.reset();
    DWORD written = 0;
    size_t sent = 0;
    while (sent < request.size() &&
        WriteFile(input_write.get(), request.data() + sent,
            static_cast<DWORD>((std::min)(request.size() - sent, size_t{65536})),
            &written, nullptr) && written) sent += written;
    if (sent != request.size()) {
      TerminateJobObject(job_.get(), 1); result->Error("document_worker_died"); return;
    }
    input_write.reset();
    std::vector<uint8_t> response;
    std::array<uint8_t, 65536> buffer{};
    for (;;) {
      DWORD read = 0;
      if (!ReadFile(output_read.get(), buffer.data(),
                    static_cast<DWORD>(buffer.size()), &read, nullptr)) {
        if (GetLastError() == ERROR_BROKEN_PIPE) break;
        TerminateJobObject(job_.get(), 1); result->Error("document_worker_died"); return;
      }
      if (!read) break;
      if (response.size() + read > kMaxResponse) {
        TerminateJobObject(job_.get(), 1); result->Error("document_worker_output_limit"); return;
      }
      response.insert(response.end(), buffer.begin(), buffer.begin() + read);
    }
    const DWORD wait = WaitForSingleObject(process_handle.get(), 120000);
    if (wait != WAIT_OBJECT_0) {
      TerminateJobObject(job_.get(), 1); WaitForSingleObject(process_handle.get(), INFINITE);
      result->Error("document_worker_timeout"); return;
    }
    DWORD exit_code = 1; GetExitCodeProcess(process_handle.get(), &exit_code);
    if (exit_code != 0 || response.empty()) result->Error("document_worker_died");
    else result->Success(Value(response));
  }

  flutter::MethodChannel<Value> channel_;
  std::mutex mutex_;
  Handle job_;
  bool running_ = false;
  std::thread thread_;
};

std::unique_ptr<Broker> broker;
}  // namespace

void RegisterDocumentWorkerBroker(flutter::BinaryMessenger* messenger) {
  broker = std::make_unique<Broker>(messenger);
}
void StopDocumentWorkerBroker() { broker.reset(); }
