#include <jni.h>

#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include "document_engine.h"

using mobilka::documents::Bytes;
using mobilka::documents::Error;
using mobilka::documents::Language;
using mobilka::documents::Limits;
using mobilka::documents::Operation;
using mobilka::documents::Request;

namespace {
void u32(std::vector<uint8_t>& out, uint32_t value) {
  out.push_back(value >> 24); out.push_back(value >> 16);
  out.push_back(value >> 8); out.push_back(value);
}

void frame(std::vector<uint8_t>& out, const uint8_t* job, uint8_t kind,
           uint32_t index, uint32_t page, uint32_t offset, uint8_t status,
           uint32_t width, uint32_t height, const std::string& text) {
  u32(out, static_cast<uint32_t>(47 + text.size()));
  out.push_back(1); out.push_back(kind);
  out.insert(out.end(), job, job + 16);
  u32(out, index); u32(out, page); u32(out, offset); out.push_back(status);
  u32(out, 0); u32(out, width); u32(out, height);
  u32(out, static_cast<uint32_t>(text.size()));
  out.insert(out.end(), text.begin(), text.end());
}

class ByteArray {
 public:
  ByteArray(JNIEnv* env, jbyteArray value) : env_(env), value_(value),
      size_(value ? env->GetArrayLength(value) : 0),
      data_(value ? env->GetByteArrayElements(value, nullptr) : nullptr) {}
  ~ByteArray() { if (data_) env_->ReleaseByteArrayElements(value_, data_, JNI_ABORT); }
  Bytes bytes() const { return {reinterpret_cast<uint8_t*>(data_), static_cast<size_t>(size_)}; }
 private:
  JNIEnv* env_; jbyteArray value_; jsize size_; jbyte* data_;
};
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_rslnmzhn_mobilka_documents_DocumentWorkerProcessor_nativeReady(JNIEnv*, jobject) {
  return JNI_TRUE;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rslnmzhn_mobilka_documents_DocumentWorkerProcessor_nativeProcess(
    JNIEnv* env, jobject, jbyteArray job_array, jint operation, jint language,
    jint first_page, jint page_count, jintArray limits_array, jbyteArray source_array,
    jbyteArray eng_array, jbyteArray rus_array) {
  if (!job_array || env->GetArrayLength(job_array) != 16 || !limits_array ||
      env->GetArrayLength(limits_array) != 10) return nullptr;
  ByteArray job(env, job_array), source(env, source_array), eng(env, eng_array), rus(env, rus_array);
  jint raw[10]; env->GetIntArrayRegion(limits_array, 0, 10, raw);
  if (env->ExceptionCheck() || operation < 0 || operation > 2 || language < 0 || language > 2 ||
      first_page < 1 || page_count < 1) return nullptr;
  Limits limits{static_cast<size_t>(raw[0]), raw[1], raw[2], raw[3],
      static_cast<size_t>(raw[4]), static_cast<size_t>(raw[5]),
      static_cast<size_t>(raw[6]), static_cast<size_t>(raw[7])};
  Request request{static_cast<Operation>(operation), static_cast<Language>(language),
      first_page, page_count, limits, source.bytes()};
  const auto result = mobilka::documents::process(request, eng.bytes(), rus.bytes());
  std::vector<uint8_t> response;
  uint32_t offset = 0;
  if (result.error == Error::none) {
    for (size_t index = 0; index < result.pages.size(); ++index) {
      const auto& page = result.pages[index];
      frame(response, job.bytes().data, 0, static_cast<uint32_t>(index), page.number,
          offset, operation == 0 ? 0 : 1, page.width, page.height, page.text);
      offset += static_cast<uint32_t>(page.text.size());
    }
    frame(response, job.bytes().data, 1, static_cast<uint32_t>(result.pages.size()),
        0, offset, 0, 0, 0, {});
  } else {
    const char* code = result.error == Error::invalid_request ? "invalid_document_worker_request" :
        result.error == Error::unsupported ? "document_worker_unsupported" :
        result.error == Error::invalid_document ? "invalid_document" :
        result.error == Error::limit ? "document_limit" : "document_worker_unavailable";
    frame(response, job.bytes().data, 2, 0, 0, 0, 0, 0, 0, code);
  }
  if (response.size() > 1048576 + 4096 || response.size() > std::numeric_limits<jsize>::max()) return nullptr;
  auto output = env->NewByteArray(static_cast<jsize>(response.size()));
  if (output) env->SetByteArrayRegion(output, 0, static_cast<jsize>(response.size()),
      reinterpret_cast<const jbyte*>(response.data()));
  return output;
}
