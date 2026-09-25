/**
 * Android remote-process Node launcher.
 *
 * This JNI entrypoint is called only by AndroidNodeProcessService. It loads the
 * pinned arm64 libnode.so and runs its exported node::Start() on the service's
 * worker thread. The service process owns stdout/stderr and the Node event loop;
 * neither a second VM nor a writable extracted executable is created.
 */
#include <jni.h>
#include <dlfcn.h>
#include <unistd.h>
#include <cstdlib>
#include <cstdio>
#include <string>
#include <vector>

namespace {

std::string utf8(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  const char* raw = env->GetStringUTFChars(value, nullptr);
  if (raw == nullptr) return {};
  std::string result(raw);
  env->ReleaseStringUTFChars(value, raw);
  return result;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_mgread_mgread_1plugin_1runtime_AndroidNodeNative_run(
    JNIEnv* env, jobject, jobjectArray arguments, jstring home,
    jstring temporary_directory, jstring working_directory,
    jint stdout_fd, jint stderr_fd) {
  if (stdout_fd < 0 || stderr_fd < 0 ||
      dup2(stdout_fd, STDOUT_FILENO) < 0 ||
      dup2(stderr_fd, STDERR_FILENO) < 0) {
    return -1;
  }
  close(stdout_fd);
  close(stderr_fd);

  const std::string home_path = utf8(env, home);
  const std::string temp_path = utf8(env, temporary_directory);
  const std::string work_path = utf8(env, working_directory);
  if (home_path.empty() || temp_path.empty() || work_path.empty() ||
      setenv("HOME", home_path.c_str(), 1) != 0 ||
      setenv("TMPDIR", temp_path.c_str(), 1) != 0 ||
      chdir(work_path.c_str()) != 0) {
    std::fputs("mgread_node_environment_failed\n", stderr);
    return -2;
  }
  // The application never accepts ambient Node options as a Runtime input.
  unsetenv("NODE_OPTIONS");
  unsetenv("NODE_PATH");

  const jsize count = env->GetArrayLength(arguments);
  if (count < 2 || count > 24) return -3;
  std::vector<std::string> values;
  values.reserve(static_cast<size_t>(count));
  for (jsize index = 0; index < count; ++index) {
    auto item = static_cast<jstring>(env->GetObjectArrayElement(arguments, index));
    values.push_back(utf8(env, item));
    env->DeleteLocalRef(item);
    if (values.back().empty() || values.back().size() > 8192) return -3;
  }
  std::vector<char*> argv;
  argv.reserve(values.size() + 1);
  for (std::string& value : values) argv.push_back(value.data());
  argv.push_back(nullptr);

  void* library = dlopen("libnode.so", RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    std::fputs("mgread_libnode_load_failed\n", stderr);
    return -4;
  }
  // Verified against the pinned nodejs-mobile 24.21.0 arm64 artifact.
  using NodeStart = int (*)(int, char**);
  auto start = reinterpret_cast<NodeStart>(dlsym(library, "_ZN4node5StartEiPPc"));
  if (start == nullptr) {
    std::fputs("mgread_libnode_start_missing\n", stderr);
    return -5;
  }
  return start(static_cast<int>(values.size()), argv.data());
}
