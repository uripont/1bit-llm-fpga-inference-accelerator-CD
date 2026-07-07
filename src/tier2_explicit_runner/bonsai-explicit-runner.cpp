// Pinned reference: external/llama.cpp at commit 1ec7ba0c14f33f17e980daeeda5f35b225d41994.
// Main source references to be used:
//   - external/llama.cpp/ggml/src/gguf.cpp                 GGUF container parsing
//   - external/llama.cpp/src/llama-model-loader.cpp        tensor metadata/loading path
//   - external/llama.cpp/src/models/qwen3.cpp              Qwen3 block graph
//   - external/llama.cpp/src/llama-kv-cache.cpp             KV-cache storage/update path
//   - external/llama.cpp/ggml/src/ggml-common.h            quantized block layouts
//   - external/llama.cpp/ggml/src/ggml-quants.c            Q1_0 dequantization
//   - external/llama.cpp/ggml/src/ggml-cpu/quants.c        Q1_0 CPU dot math
//   - external/llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c      CPU graph execution
//   - external/llama.cpp/ggml/src/ggml-blas/ggml-blas.cpp  BLAS matmul path used in Tier 1

#include <cstdint>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

namespace bonsai_tier2 {

// Constants for GGUF tensor types and Q1_0 block layout for Bonsai family (avoid hardcoding on implementation)
static constexpr uint32_t GGUF_TYPE_F32 = 0;
static constexpr uint32_t GGUF_TYPE_F16 = 1;
static constexpr uint32_t GGUF_TYPE_Q1_0 = 41;
static constexpr uint32_t QK1_0 = 128;
static constexpr uint32_t Q1_0_BLOCK_BYTES = sizeof(uint16_t) + QK1_0 / 8;

struct RunConfig {
  std::string model_path = "models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf";
  std::vector<uint32_t> tokens;
  uint32_t top_k = 5;

  // To control main() runner behaviour:
  bool inspect_model = false;
  bool check_q1 = false;
  bool trace_one_token = false;
};


// Minimal CLI parsing for the stable Tier 2 modes.
std::vector<uint32_t> parse_tokens(const std::string & text) {
  std::vector<uint32_t> tokens;
  size_t start = 0;
  while (start < text.size()) {
    const size_t comma = text.find(',', start);
    const std::string item = text.substr(start, comma == std::string::npos ? comma : comma - start);
    if (!item.empty()) tokens.push_back(static_cast<uint32_t>(std::stoul(item)));
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
  return tokens;
}

RunConfig parse_args(int argc, char ** argv) {
  RunConfig config;
  for (int i = 1; i < argc; i++) {
    const std::string arg = argv[i];
    if (arg == "--model" && i + 1 < argc) {
      config.model_path = argv[++i];
    } else if (arg == "--tokens" && i + 1 < argc) {
      config.tokens = parse_tokens(argv[++i]);
    } else if (arg == "--top-k" && i + 1 < argc) {
      config.top_k = static_cast<uint32_t>(std::stoul(argv[++i]));
    } else if (arg == "--inspect-model") {
      config.inspect_model = true;
    } else if (arg == "--check-q1") {
      config.check_q1 = true;
    } else if (arg == "--trace-one-token") {
      config.trace_one_token = true;
    } else {
      throw std::runtime_error("usage: bonsai-explicit-runner [--model path] [--tokens id[,id...]] [--top-k n] [--inspect-model] [--check-q1] [--trace-one-token]");
    }
  }
  if (config.top_k == 0) throw std::runtime_error("--top-k must be greater than zero");
  return config;
}

using MetaValue = std::variant<uint8_t, int8_t, uint16_t, int16_t, uint32_t, int32_t, uint64_t, int64_t, float, double, bool, std::string>;

// binary reader for the GGUF header and directory
struct FileReader {
  std::ifstream file;

  explicit FileReader(const std::string & path) : file(path, std::ios::binary) {
    if (!file) throw std::runtime_error("cannot open model: " + path);
  }

  template <typename T> T read() {
    T value;
    file.read(reinterpret_cast<char *>(&value), sizeof(T));
    if (!file) throw std::runtime_error("unexpected EOF");
    return value;
  }

  std::string read_string() {
    const uint64_t size = read<uint64_t>();
    std::string value(size, '\0');
    file.read(value.data(), static_cast<std::streamsize>(size));
    if (!file) throw std::runtime_error("bad GGUF string");
    return value;
  }
  uint64_t position() {
    return static_cast<uint64_t>(file.tellg());
  }
};

struct TensorView {
  std::string name;
  std::vector<uint64_t> dims;
  uint32_t type = 0;

  // GGUF stores tensor offsets relative to the aligned data section
  uint64_t relative_offset = 0;
  uint64_t absolute_offset = 0;
};

struct ModelView {
  std::string path;
  uint32_t gguf_version = 0;
  uint64_t metadata_count = 0;
  // Arrays are mostly tokenizer data which we can skip for now
  uint64_t skipped_array_count = 0;
  uint64_t data_start = 0;
  std::unordered_map<std::string, MetaValue> meta;
  std::vector<TensorView> tensors;
  std::unordered_map<std::string, size_t> tensor_index;
};

uint64_t align_to(uint64_t x, uint64_t alignment) {
  return ((x + alignment - 1) / alignment) * alignment;
}
std::string type_name(uint32_t type) {
  if (type == GGUF_TYPE_F32) return "f32";
  if (type == GGUF_TYPE_F16) return "f16";
  if (type == GGUF_TYPE_Q1_0) return "q1_0";
  return "type_" + std::to_string(type);
}
std::string meta_to_string(const MetaValue & value) {
  return std::visit([](const auto & v) -> std::string {
    using T = std::decay_t<decltype(v)>;
    if constexpr (std::is_same_v<T, std::string>) return v;
    else if constexpr (std::is_same_v<T, bool>) return v ? "true" : "false";
    else return std::to_string(v);
  }, value);
}

MetaValue read_scalar(FileReader & reader, uint32_t type) {
  switch (type) {
    case 0: return reader.read<uint8_t>();
    case 1: return reader.read<int8_t>();
    case 2: return reader.read<uint16_t>();
    case 3: return reader.read<int16_t>();
    case 4: return reader.read<uint32_t>();
    case 5: return reader.read<int32_t>();
    case 6: return reader.read<float>();
    case 7: return reader.read<bool>();
    case 8: return reader.read_string();
    case 10: return reader.read<uint64_t>();
    case 11: return reader.read<int64_t>();
    case 12: return reader.read<double>();
    default: throw std::runtime_error("unsupported GGUF metadata type: " + std::to_string(type));
  }
}

void skip_array(FileReader & reader) {
  const uint32_t element_type = reader.read<uint32_t>();
  const uint64_t count = reader.read<uint64_t>();
  for (uint64_t i = 0; i < count; i++) {
    (void)read_scalar(reader, element_type);
  }
}

ModelView load_model_view(const std::string & model_path) {
  FileReader reader(model_path);
  ModelView model;
  model.path = model_path;

  // Same high-level layout used by gguf.cpp: header, metadata, tensor directory, data section:
  const uint32_t magic = reader.read<uint32_t>();
  if (magic != 0x46554747u) throw std::runtime_error("not a GGUF file");
  model.gguf_version = reader.read<uint32_t>();
  if (model.gguf_version != 3) throw std::runtime_error("unsupported GGUF version");

  // GGUF v3 stores the number of tensor records before the metadata records
  const uint64_t tensor_count = reader.read<uint64_t>();
  model.metadata_count = reader.read<uint64_t>();

  // Keep scalar metadata needed for Bonsai/Qwen3 shape checks; skip large arrays
  for (uint64_t i = 0; i < model.metadata_count; i++) {
    const std::string key = reader.read_string();
    const uint32_t type = reader.read<uint32_t>();
    if (type == 9) {
      skip_array(reader);
      model.skipped_array_count++;
    } else {
      model.meta[key] = read_scalar(reader, type);
    }
  }

  // Tensor records tell us names, shapes, types, and offsets without reading weights
  model.tensors.reserve(tensor_count);
  for (uint64_t i = 0; i < tensor_count; i++) {
    TensorView tensor;
    tensor.name = reader.read_string();
    const uint32_t ndims = reader.read<uint32_t>();
    tensor.dims.resize(ndims);
    for (uint32_t d = 0; d < ndims; d++) tensor.dims[d] = reader.read<uint64_t>();
    tensor.type = reader.read<uint32_t>();
    tensor.relative_offset = reader.read<uint64_t>();
    model.tensor_index[tensor.name] = model.tensors.size();
    model.tensors.push_back(std::move(tensor));
  }

  // llama.cpp defaults to 32-byte alignment (unless general.alignment overrides it)
  uint64_t alignment = 32;
  if (auto it = model.meta.find("general.alignment"); it != model.meta.end()) {
    if (const auto * value = std::get_if<uint32_t>(&it->second)) alignment = *value;
  }
  if (alignment == 0 || (alignment & (alignment - 1)) != 0) {
    throw std::runtime_error("invalid GGUF alignment");
  }

  // Convert offsets from "relative to tensor data" into absolute file positions
  model.data_start = align_to(reader.position(), alignment);
  for (TensorView & tensor : model.tensors) {
    tensor.absolute_offset = model.data_start + tensor.relative_offset;
  }
  return model;
}

// Q1_0 format helpers
// anchors: ggml-common.h, ggml-quants.c, ggml-cpu/quants.c.
struct Q1Metrics {
  uint64_t calls = 0;
  uint64_t rows = 0;
  uint64_t dot_elements = 0;
  uint64_t groups_128 = 0;
};

void add_q1_metrics(Q1Metrics & dst, const Q1Metrics & src) {
  dst.calls += src.calls;
  dst.rows += src.rows;
  dst.dot_elements += src.dot_elements;
  dst.groups_128 += src.groups_128;
}

float fp16_to_f32(uint16_t h) {
  // Q1_0 stores each block scale as ggml_half before its 128 packed sign bits.
  const uint32_t sign = (uint32_t(h) & 0x8000u) << 16;
  uint32_t exp = (uint32_t(h) >> 10) & 0x1fu;
  uint32_t mant = uint32_t(h) & 0x03ffu;
  uint32_t out = 0;

  if (exp == 0) {
    // Half zero: exponent is zero, so the mantissa needs special handling
    if (mant == 0) {
      // Signed zero maps directly to the float sign bit
      out = sign;
    } else {
      // Normalize by shifting until the hidden leading bit appears
      exp = 1;
      while ((mant & 0x0400u) == 0) {
        mant <<= 1;
        exp--;
      }
      // Drop the hidden leading bit and re-bias the exponent from half to float
      mant &= 0x03ffu;
      out = sign | ((exp + 127 - 15) << 23) | (mant << 13);
    }
  } else if (exp == 31) {
    // Half Inf/NaN: preserve the payload bits while expanding to float format
    out = sign | 0x7f800000u | (mant << 13);
  } else {
    // Normal half: keep sign/mantissa and change exponent bias from 15 to 127
    out = sign | ((exp + 127 - 15) << 23) | (mant << 13);
  }

  float value = 0.0f;
  std::memcpy(&value, &out, sizeof(value));
  return value;
}

uint64_t q1_0_row_size(uint64_t cols) {
  // GGML Q1_0 rows are a sequence of block_q1_0 groups, each covering 128 columns
  if (cols % QK1_0 != 0) throw std::runtime_error("Q1_0 row is not block-aligned");
  return (cols / QK1_0) * Q1_0_BLOCK_BYTES;
}

std::vector<uint8_t> read_q1_0_row(const ModelView & model, const TensorView & tensor, uint64_t row) {
  if (tensor.type != GGUF_TYPE_Q1_0) throw std::runtime_error("tensor is not Q1_0: " + tensor.name);
  if (tensor.dims.size() != 2) throw std::runtime_error("Q1_0 row read expects rank-2 tensor: " + tensor.name);
  
  const uint64_t cols = tensor.dims[0];
  const uint64_t rows = tensor.dims[1];
  if (row >= rows) throw std::runtime_error("Q1_0 row index out of range: " + tensor.name);

  const uint64_t row_bytes = q1_0_row_size(cols);
  std::vector<uint8_t> bytes(row_bytes);
  std::ifstream file(model.path, std::ios::binary);

  if (!file) throw std::runtime_error("cannot reopen model: " + model.path);
  file.seekg(static_cast<std::streamoff>(tensor.absolute_offset + row * row_bytes));
  file.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
  if (!file) throw std::runtime_error("could not read Q1_0 row: " + tensor.name);
  return bytes;
}

std::vector<uint8_t> read_q1_0_tensor(const ModelView & model, const TensorView & tensor) {
  if (tensor.type != GGUF_TYPE_Q1_0) throw std::runtime_error("tensor is not Q1_0: " + tensor.name);
  if (tensor.dims.size() != 2) throw std::runtime_error("Q1_0 tensor read expects rank-2 tensor: " + tensor.name);

  const uint64_t cols = tensor.dims[0];
  const uint64_t rows = tensor.dims[1];
  const uint64_t bytes_total = rows * q1_0_row_size(cols);
  std::vector<uint8_t> bytes(bytes_total);
  std::ifstream file(model.path, std::ios::binary);

  if (!file) throw std::runtime_error("cannot reopen model: " + model.path);
  file.seekg(static_cast<std::streamoff>(tensor.absolute_offset));
  file.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
  if (!file) throw std::runtime_error("could not read Q1_0 tensor: " + tensor.name);
  return bytes;
}

std::vector<float> read_f32_tensor(const ModelView & model, const TensorView & tensor) {
  if (tensor.type != GGUF_TYPE_F32) throw std::runtime_error("tensor is not F32: " + tensor.name);

  uint64_t count = 1;
  for (uint64_t dim : tensor.dims) count *= dim;
  std::vector<float> values(count);
  std::ifstream file(model.path, std::ios::binary);

  if (!file) throw std::runtime_error("cannot reopen model: " + model.path);
  file.seekg(static_cast<std::streamoff>(tensor.absolute_offset));
  file.read(reinterpret_cast<char *>(values.data()), static_cast<std::streamsize>(values.size() * sizeof(float)));
  if (!file) throw std::runtime_error("could not read F32 tensor: " + tensor.name);
  return values;
}

std::vector<float> dequantize_q1_0_row(const std::vector<uint8_t> & row, uint64_t cols) {
  if (row.size() != q1_0_row_size(cols)) throw std::runtime_error("bad Q1_0 row byte count");

  std::vector<float> out(cols);
  const uint8_t * block = row.data();
  for (uint64_t base = 0; base < cols; base += QK1_0, block += Q1_0_BLOCK_BYTES) {
    // Each block begins with a half scale, followed by 16 bytes of packed sign bits
    uint16_t scale_bits = 0;
    std::memcpy(&scale_bits, block, sizeof(scale_bits));
    const float scale = fp16_to_f32(scale_bits);
    const uint8_t * signs = block + sizeof(scale_bits);

    for (uint32_t j = 0; j < QK1_0; j++) {
      // One bit selects +scale or -scale for the corresponding column
      const uint8_t bit = (signs[j >> 3] >> (j & 7)) & 1u;
      out[base + j] = bit ? scale : -scale;
    }
  }
  return out;
}

float dot_q1_0_row_f32(const std::vector<uint8_t> & row, const std::vector<float> & x) {
  if (row.size() != q1_0_row_size(x.size())) throw std::runtime_error("bad Q1_0 row/input size");

  float sum = 0.0f;
  const uint8_t * block = row.data();
  for (uint64_t base = 0; base < x.size(); base += QK1_0, block += Q1_0_BLOCK_BYTES) {
    // Same Q1_0 layout as dequantize_q1_0_row()
    uint16_t scale_bits = 0;
    std::memcpy(&scale_bits, block, sizeof(scale_bits));
    const float scale = fp16_to_f32(scale_bits);
    const uint8_t * signs = block + sizeof(scale_bits);

    for (uint32_t j = 0; j < QK1_0; j++) {
      //Avoid storing the dequantized row; reconstruct the signed weight
      const uint8_t bit = (signs[j >> 3] >> (j & 7)) & 1u;
      sum += (bit ? scale : -scale) * x[base + j];
    }
  }
  return sum;
}

float dot_q1_0_row_f32(const uint8_t * row, uint64_t row_bytes, const std::vector<float> & x) {
  if (row_bytes != q1_0_row_size(x.size())) throw std::runtime_error("bad Q1_0 row/input size");

  float sum = 0.0f;
  const uint8_t * block = row;
  for (uint64_t base = 0; base < x.size(); base += QK1_0, block += Q1_0_BLOCK_BYTES) {
    uint16_t scale_bits = 0;
    std::memcpy(&scale_bits, block, sizeof(scale_bits));
    const float scale = fp16_to_f32(scale_bits);
    const uint8_t * signs = block + sizeof(scale_bits);

    for (uint32_t j = 0; j < QK1_0; j++) {
      const uint8_t bit = (signs[j >> 3] >> (j & 7)) & 1u;
      sum += (bit ? scale : -scale) * x[base + j];
    }
  }
  return sum;
}

float dot_f32(const std::vector<float> & a, const std::vector<float> & b) {
  if (a.size() != b.size()) throw std::runtime_error("dot size mismatch");
  float sum = 0.0f;
  for (size_t i = 0; i < a.size(); i++) sum += a[i] * b[i];
  return sum;
}

std::vector<float> rms_norm(const std::vector<float> & x, const std::vector<float> & weight, float eps) {
  if (x.size() != weight.size()) throw std::runtime_error("rms_norm size mismatch");

  // RMSNorm scales the whole hidden vector by its root-mean-square magnitude.
  double mean_sq = 0.0;
  for (float value : x) mean_sq += double(value) * double(value);
  mean_sq /= double(x.size());
  const float scale = 1.0f / std::sqrt(float(mean_sq) + eps);

  //The learned norm weight is applied elementwise after RMS scaling.
  std::vector<float> out(x.size());
  for (size_t i = 0; i < x.size(); i++) out[i] = x[i] * scale * weight[i];
  return out;
}

std::vector<float> rms_norm_heads(const std::vector<float> & x, const std::vector<float> & weight, uint32_t head_dim, float eps) {
  if (weight.size() != head_dim) throw std::runtime_error("head rms_norm weight size mismatch");
  if (x.size() % head_dim != 0) throw std::runtime_error("head rms_norm input size mismatch");

  std::vector<float> out(x.size());
  const uint64_t heads = x.size() / head_dim;
  for (uint64_t head = 0; head < heads; head++) {
    // Qwen3 applies Q/K norm independently inside each attention head
    double mean_sq = 0.0;
    const uint64_t base = head * head_dim;
    for (uint32_t d = 0; d < head_dim; d++) mean_sq += double(x[base + d]) * double(x[base + d]);
    
    
    mean_sq /= double(head_dim);
    const float scale = 1.0f / std::sqrt(float(mean_sq) + eps);
    for (uint32_t d = 0; d < head_dim; d++) out[base + d] = x[base + d] * scale * weight[d];
  }
  return out;
}


// Future accelerator calls
struct BackendMetrics {
  Q1Metrics transformer_q1;
  Q1Metrics lm_head_q1;
  uint64_t attention_calls = 0;
  uint64_t attention_score_mac = 0;
  uint64_t attention_value_mac = 0;
};

struct DecodeMetrics {
  uint64_t tokens = 0;
  uint64_t layers = 0;
  uint64_t rms_norms = 0;
  uint64_t q1_backend_calls = 0;
  uint64_t attention_backend_calls = 0;
  uint64_t residual_adds = 0;
  uint64_t silu_gate_products = 0;
  uint64_t lm_head_calls = 0;
};

struct LayerCache {
  std::vector<std::vector<float>> keys;
  std::vector<std::vector<float>> values;
};

struct TopToken {
  uint32_t token = 0;
  float logit = 0.0f;
  float probability = 0.0f;
};

// ---------------------------------------------------------------------------
// Bonsai/Qwen3 shape
// from models/qwen3.cpp and Bonsai GGUF metadata
// load from metadata, then assert Bonsai-1.7B expected dimensions

struct ModelShape {
  uint32_t n_layer = 0;
  uint32_t n_embd = 0;
  uint32_t n_ff = 0;
  uint32_t n_head = 0;
  uint32_t n_head_kv = 0;
  uint32_t head_dim = 0;
  uint32_t n_ctx = 0;
  uint32_t n_vocab = 0;
  float rope_freq_base = 1000000.0f;
  float rope_freq_scale = 1.0f;
  float rms_eps = 0.0f;
};

const TensorView & require_tensor(const ModelView & model, const std::string & name) {
  // Fail early if the GGUF does not contain the Qwen3 tensor we plan to use
  auto it = model.tensor_index.find(name);
  if (it == model.tensor_index.end()) throw std::runtime_error("missing tensor: " + name);
  return model.tensors[it->second];
}

uint32_t require_meta_u32(const ModelView & model, const std::string & key) {
  // Metadata type checks keep later shape arithmetic from silently using bad data.
  auto it = model.meta.find(key);
  if (it == model.meta.end()) throw std::runtime_error("missing metadata: " + key);
  const auto * value = std::get_if<uint32_t>(&it->second);
  if (!value) throw std::runtime_error("metadata has wrong type: " + key);
  return *value;
}
float require_meta_f32(const ModelView & model, const std::string & key) {
  auto it = model.meta.find(key);
  if (it == model.meta.end()) throw std::runtime_error("missing metadata: " + key);
  const auto * value = std::get_if<float>(&it->second);
  if (!value) throw std::runtime_error("metadata has wrong type: " + key);
  return *value;
}

std::string require_meta_string(const ModelView & model, const std::string & key) {
  auto it = model.meta.find(key);
  if (it == model.meta.end()) throw std::runtime_error("missing metadata: " + key);
  const auto * value = std::get_if<std::string>(&it->second);
  
  if (!value) throw std::runtime_error("metadata has wrong type: " + key);
  return *value;
}

std::string layer_tensor(uint32_t layer, const std::string & suffix) {
  // llama.cpp names Qwen3 block tensors as blk.<layer>.<role>.weight
  return "blk." + std::to_string(layer) + "." + suffix;
}

void require_dims(const TensorView & tensor, std::initializer_list<uint64_t> expected) {
  // Shape checks encode the tensor contract copied from models/qwen3.cpp.
  if (tensor.dims.size() != expected.size()) throw std::runtime_error("bad tensor rank: " + tensor.name);
  size_t i = 0;
  for (uint64_t dim : expected) {
    if (tensor.dims[i++] != dim) throw std::runtime_error("bad tensor shape: " + tensor.name);
  }
}

// Shape validation mirrors the required tensors in models/qwen3.cpp.
ModelShape load_and_validate_shape(const ModelView & model) {
  if (require_meta_string(model, "general.architecture") != "qwen3") {
    throw std::runtime_error("expected qwen3 architecture");
  }

  ModelShape shape;
  shape.n_layer = require_meta_u32(model, "qwen3.block_count");
  shape.n_embd = require_meta_u32(model, "qwen3.embedding_length");
  shape.n_ff = require_meta_u32(model, "qwen3.feed_forward_length");
  shape.n_head = require_meta_u32(model, "qwen3.attention.head_count");
  shape.n_head_kv = require_meta_u32(model, "qwen3.attention.head_count_kv");
  shape.head_dim = require_meta_u32(model, "qwen3.attention.key_length");
  shape.n_ctx = require_meta_u32(model, "qwen3.context_length");
  shape.rms_eps = require_meta_f32(model, "qwen3.attention.layer_norm_rms_epsilon");
  shape.rope_freq_base = require_meta_f32(model, "qwen3.rope.freq_base");
  shape.rope_freq_scale = 1.0f / require_meta_f32(model, "qwen3.rope.scaling.factor");
  shape.n_vocab = static_cast<uint32_t>(require_tensor(model, "token_embd.weight").dims.at(1));

  if (shape.n_layer != 28 || shape.n_embd != 2048 || shape.n_ff != 6144 ||
      shape.n_head != 16 || shape.n_head_kv != 8 || shape.head_dim != 128) {
    throw std::runtime_error("unexpected Bonsai-1.7B/Qwen3 dimensions");
  }

  require_dims(require_tensor(model, "token_embd.weight"), {shape.n_embd, shape.n_vocab});
  require_dims(require_tensor(model, "output_norm.weight"), {shape.n_embd});

  const uint64_t n_q = uint64_t(shape.n_head) * shape.head_dim;
  const uint64_t n_kv = uint64_t(shape.n_head_kv) * shape.head_dim;
  for (uint32_t layer = 0; layer < shape.n_layer; layer++) {
    require_dims(require_tensor(model, layer_tensor(layer, "attn_norm.weight")), {shape.n_embd});
    require_dims(require_tensor(model, layer_tensor(layer, "attn_q.weight")), {shape.n_embd, n_q});
    require_dims(require_tensor(model, layer_tensor(layer, "attn_k.weight")), {shape.n_embd, n_kv});
    require_dims(require_tensor(model, layer_tensor(layer, "attn_v.weight")), {shape.n_embd, n_kv});
    require_dims(require_tensor(model, layer_tensor(layer, "attn_output.weight")), {n_q, shape.n_embd});
    require_dims(require_tensor(model, layer_tensor(layer, "attn_q_norm.weight")), {shape.head_dim});
    require_dims(require_tensor(model, layer_tensor(layer, "attn_k_norm.weight")), {shape.head_dim});
    require_dims(require_tensor(model, layer_tensor(layer, "ffn_norm.weight")), {shape.n_embd});
    require_dims(require_tensor(model, layer_tensor(layer, "ffn_gate.weight")), {shape.n_embd, shape.n_ff});
    require_dims(require_tensor(model, layer_tensor(layer, "ffn_up.weight")), {shape.n_embd, shape.n_ff});
    require_dims(require_tensor(model, layer_tensor(layer, "ffn_down.weight")), {shape.n_ff, shape.n_embd});
  }

  return shape;
}

// ---------------------------------------------------------------------------
// One-token forward path
// ---------------------------------------------------------------------------
// Main source: models/qwen3.cpp:
// ->embed 
// -> per layer: (attn norm, Q/K/V, Q/K norm, RoPE, KV append, attention,
// attn output, residual, FFN norm, gate/up, SiLU*up, down, residual) 
// -> final norm 
// -> LM head 
// -> optional argmax
class Runner {
public:
  Runner(ModelView model, ModelShape shape)
      : model_(std::move(model)), shape_(shape), kv_cache_(shape.n_layer) {}

  void inspect() const {
    // Report the Bonsai GGUF tensor count and each tensor's name, dimensions, and type.
    std::cout << "model_path=" << model_.path << "\n";
    std::cout << "gguf_version=" << model_.gguf_version << "\n";
    std::cout << "metadata_count=" << model_.metadata_count
              << " scalar_metadata=" << model_.meta.size()
              << " skipped_arrays=" << model_.skipped_array_count << "\n";
    std::cout << "data_start=" << model_.data_start << "\n";
    print_meta("general.architecture");
    print_meta("general.name");
    print_meta("qwen3.block_count");
    print_meta("qwen3.embedding_length");
    print_meta("qwen3.feed_forward_length");
    print_meta("qwen3.attention.head_count");
    print_meta("qwen3.attention.head_count_kv");
    print_meta("qwen3.attention.key_length");
    print_meta("qwen3.attention.layer_norm_rms_epsilon");
    std::cout << "validated_shape"
              << " layers=" << shape_.n_layer
              << " hidden=" << shape_.n_embd
              << " ffn=" << shape_.n_ff
              << " heads=" << shape_.n_head
              << " kv_heads=" << shape_.n_head_kv
              << " head_dim=" << shape_.head_dim
              << " vocab=" << shape_.n_vocab << "\n";

    std::cout << "tensor_count=" << model_.tensors.size() << "\n";
    for (const TensorView & tensor : model_.tensors) {
      std::cout << "tensor " << tensor.name << " type=" << type_name(tensor.type)
                << " dims=[";
      for (size_t i = 0; i < tensor.dims.size(); i++) {
        if (i) std::cout << ",";
        std::cout << tensor.dims[i];
      }
      std::cout << "] offset=" << tensor.absolute_offset << "\n";
    }
  }

  void trace_one_token(uint32_t token, uint32_t top_k) {
    const uint64_t position = decode_.tokens;
    decode_.tokens++;
    decode_.layers += shape_.n_layer;
    decode_.rms_norms += uint64_t(shape_.n_layer) * 5 + 1;
    decode_.q1_backend_calls += uint64_t(shape_.n_layer) * 7 + 1;
    decode_.attention_backend_calls += shape_.n_layer;
    decode_.residual_adds += uint64_t(shape_.n_layer) * 2;
    decode_.silu_gate_products += shape_.n_layer;
    decode_.lm_head_calls++;

    std::cout << "trace_decode token=" << token
              << " position=" << position
              << " layers=" << shape_.n_layer
              << " hidden=" << shape_.n_embd
              << " ffn=" << shape_.n_ff
              << " heads=" << shape_.n_head
              << " kv_heads=" << shape_.n_head_kv
              << " head_dim=" << shape_.head_dim << "\n";
    std::cout << "decode_step embed token_embd.weight -> hidden\n";
    std::vector<float> hidden = embedding_lookup(token);

    // Decode each layer in Bonsai/Qwen3, using the Q1_0 backend for all matrix-vector products
    for (uint32_t layer = 0; layer < shape_.n_layer; layer++) {
      Q1Metrics layer_q1;
      const std::vector<float> attn_in = rms_norm(hidden, read_f32_tensor(model_, require_tensor(model_, layer_tensor(layer, "attn_norm.weight"))), shape_.rms_eps);
      std::vector<float> q = q1_matvec_backend(layer_tensor(layer, "attn_q.weight"), attn_in, metrics_.transformer_q1, &layer_q1);
      std::vector<float> k = q1_matvec_backend(layer_tensor(layer, "attn_k.weight"), attn_in, metrics_.transformer_q1, &layer_q1);
      const std::vector<float> v = q1_matvec_backend(layer_tensor(layer, "attn_v.weight"), attn_in, metrics_.transformer_q1, &layer_q1);
      q = rms_norm_heads(q, read_f32_tensor(model_, require_tensor(model_, layer_tensor(layer, "attn_q_norm.weight"))), shape_.head_dim, shape_.rms_eps);
      k = rms_norm_heads(k, read_f32_tensor(model_, require_tensor(model_, layer_tensor(layer, "attn_k_norm.weight"))), shape_.head_dim, shape_.rms_eps);
      apply_rope(q, shape_.n_head, position);
      apply_rope(k, shape_.n_head_kv, position);
      const std::vector<float> attention_out = attention_backend(layer, q, k, v);
      const std::vector<float> projected_attention = q1_matvec_backend(layer_tensor(layer, "attn_output.weight"), attention_out, metrics_.transformer_q1, &layer_q1);

      std::vector<float> ffn_input = hidden;
      for (size_t i = 0; i < ffn_input.size(); i++) ffn_input[i] += projected_attention[i];
      const std::vector<float> ffn_normed = rms_norm(ffn_input, read_f32_tensor(model_, require_tensor(model_, layer_tensor(layer, "ffn_norm.weight"))), shape_.rms_eps);
      const std::vector<float> ffn_gate = q1_matvec_backend(layer_tensor(layer, "ffn_gate.weight"), ffn_normed, metrics_.transformer_q1, &layer_q1);
      const std::vector<float> ffn_up = q1_matvec_backend(layer_tensor(layer, "ffn_up.weight"), ffn_normed, metrics_.transformer_q1, &layer_q1);

      std::vector<float> gated(ffn_gate.size());
      for (size_t i = 0; i < gated.size(); i++) {
        const float x = ffn_gate[i];
        gated[i] = (x / (1.0f + std::exp(-x))) * ffn_up[i];
      }
      const std::vector<float> ffn_out = q1_matvec_backend(layer_tensor(layer, "ffn_down.weight"), gated, metrics_.transformer_q1, &layer_q1);
      hidden = ffn_input;
      for (size_t i = 0; i < hidden.size(); i++) hidden[i] += ffn_out[i];

      // Reporting decode information
      std::cout << "decode_layer layer=" << layer
                << " q1_backend_calls=7"
                << " q1_rows=" << layer_q1.rows
                << " q1_dot_elements=" << layer_q1.dot_elements
                << " q1_groups_128=" << layer_q1.groups_128
                << " attention_backend_calls=1"
                << " rms_norms=5"
                << " residual_adds=2"
                << " silu_gate_products=1"
                << " tensors=[attn_q,attn_k,attn_v,attn_output,ffn_gate,ffn_up,ffn_down]\n";
    }

    Q1Metrics lm_head_q1;
    hidden = rms_norm(hidden, read_f32_tensor(model_, require_tensor(model_, "output_norm.weight")), shape_.rms_eps);
    const std::vector<float> logits = q1_matvec_backend("token_embd.weight", hidden, metrics_.lm_head_q1, &lm_head_q1);
    const std::vector<TopToken> top = top_tokens(logits, top_k);
    std::cout << "decode_step output_norm -> lm_head_q1 -> logits\n";
    std::cout << "decode_summary"
              << " tokens=" << decode_.tokens
              << " layers=" << decode_.layers
              << " rms_norms=" << decode_.rms_norms
              << " q1_backend_calls=" << decode_.q1_backend_calls
              << " attention_backend_calls=" << decode_.attention_backend_calls
              << " residual_adds=" << decode_.residual_adds
              << " silu_gate_products=" << decode_.silu_gate_products
              << " lm_head_calls=" << decode_.lm_head_calls
              << " logits=" << logits.size()
              << " lm_head_q1_rows=" << lm_head_q1.rows
              << " lm_head_q1_dot_elements=" << lm_head_q1.dot_elements
              << " lm_head_q1_groups_128=" << lm_head_q1.groups_128 << "\n";
    if (!top.empty()) {
      std::cout << "generated_token token=" << top.front().token
                << " probability=" << top.front().probability
                << " logit=" << top.front().logit << "\n";
      for (size_t i = 0; i < top.size(); i++) {
        std::cout << "top_token rank=" << (i + 1)
                  << " token=" << top[i].token
                  << " probability=" << top[i].probability
                  << " logit=" << top[i].logit << "\n";
      }
    }
  }

  void check_q1() {
    // Exercise one Bonsai Q1_0 row
    const TensorView & tensor = require_tensor(model_, "blk.0.attn_q.weight");
    const uint64_t cols = tensor.dims.at(0);
    const uint64_t row = 7;
    const std::vector<uint8_t> packed = read_q1_0_row(model_, tensor, row);

    std::vector<float> x(cols);
    for (uint64_t i = 0; i < cols; i++) x[i] = std::sin(float(i) * 0.013f);

    const std::vector<float> dequant = dequantize_q1_0_row(packed, cols);
    const float ref_dot = dot_f32(dequant, x);
    const float direct_dot = dot_q1_0_row_f32(packed, x);
    const float abs_err = std::fabs(ref_dot - direct_dot);
    if (abs_err > 1e-4f) throw std::runtime_error("Q1_0 direct dot does not match dequantized reference");

    Q1Metrics matvec_metrics;
    // Verify that the backend matvec matches the dequantized reference for a few rows
    const std::vector<float> y = q1_matvec_backend(tensor.name, x, metrics_.transformer_q1, &matvec_metrics);
    const uint64_t check_rows[] = {0, row, tensor.dims.at(1) - 1};
    float max_matvec_err = 0.0f;
    for (uint64_t check_row : check_rows) {
      const std::vector<uint8_t> row_bytes = read_q1_0_row(model_, tensor, check_row);
      const std::vector<float> row_dequant = dequantize_q1_0_row(row_bytes, cols);
      const float row_ref = dot_f32(row_dequant, x);
      max_matvec_err = std::max(max_matvec_err, std::fabs(row_ref - y.at(check_row)));
    }
    if (max_matvec_err > 1e-4f) throw std::runtime_error("Q1_0 matvec does not match dequantized reference rows");

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "check_q1 tensor=" << tensor.name
              << " row=" << row
              << " cols=" << cols
              << " row_bytes=" << packed.size()
              << " groups_128=" << cols / QK1_0 << "\n";
    std::cout << "check_q1 ref_dot=" << ref_dot
              << " direct_dot=" << direct_dot
              << " abs_err=" << abs_err << "\n";
    std::cout << "check_q1 matvec_rows=" << y.size()
              << " matvec_dot_elements=" << matvec_metrics.dot_elements
              << " matvec_groups_128=" << matvec_metrics.groups_128
              << " matvec_max_ref_err=" << max_matvec_err << "\n";
    std::cout << "check_q1=ok\n";
  }

  const BackendMetrics & metrics() const { return metrics_; }
  const DecodeMetrics & decode_metrics() const { return decode_; }

private:
  std::vector<float> embedding_lookup(uint32_t token) const {
    if (token >= shape_.n_vocab) throw std::runtime_error("token id out of range");
    // GGUF stores token embeddings as rows of token_embd.weight, quantized in Q1_0.
    const TensorView & tensor = require_tensor(model_, "token_embd.weight");
    const std::vector<uint8_t> row = read_q1_0_row(model_, tensor, token);
    return dequantize_q1_0_row(row, shape_.n_embd);
  }

  void apply_rope(std::vector<float> & x, uint32_t heads, uint64_t position) const {
    if (x.size() != uint64_t(heads) * shape_.head_dim) throw std::runtime_error("RoPE input size mismatch");
    if (shape_.head_dim % 2 != 0) throw std::runtime_error("RoPE head dimension must be even");

    const uint32_t half = shape_.head_dim / 2;
    for (uint32_t head = 0; head < heads; head++) {
      const uint64_t base = uint64_t(head) * shape_.head_dim;
      for (uint32_t d = 0; d < half; d++) {
        // Qwen3 uses llama.cpp's NeoX RoPE layout: channel d pairs with d + head_dim/2 (impl detail)
        const float theta = float(position) * shape_.rope_freq_scale /
                            std::pow(shape_.rope_freq_base, float(2 * d) / float(shape_.head_dim));
        const float c = std::cos(theta);
        const float s = std::sin(theta);
        const float x0 = x[base + d];
        const float x1 = x[base + half + d];
        x[base + d] = x0 * c - x1 * s;
        x[base + half + d] = x0 * s + x1 * c;
      }
    }
  }

  std::vector<TopToken> top_tokens(const std::vector<float> & logits, size_t k) const {
    if (logits.empty()) return {};

    // Subtracting the max logit keeps the softmax exponentials in a stable range.
    float max_logit = -std::numeric_limits<float>::infinity();
    for (float logit : logits) max_logit = std::max(max_logit, logit);

    double denom = 0.0;
    for (float logit : logits) denom += std::exp(double(logit - max_logit));
    if (denom == 0.0) throw std::runtime_error("logit softmax denominator is zero");

    std::vector<uint32_t> indices(logits.size());
    for (uint32_t i = 0; i < indices.size(); i++) indices[i] = i;
    const size_t keep = std::min(k, indices.size());
    // Sort only the requested top-k entries
    std::partial_sort(indices.begin(), indices.begin() + keep, indices.end(),
        [&](uint32_t a, uint32_t b) { return logits[a] > logits[b]; });

    std::vector<TopToken> out;
    out.reserve(keep);
    for (size_t i = 0; i < keep; i++) {
      const uint32_t token = indices[i];
      // Probability is still normalized over the full vocab
      const double probability = std::exp(double(logits[token] - max_logit)) / denom;
      out.push_back({token, logits[token], static_cast<float>(probability)});
    }
    return out;
  }

  std::vector<float> attention_backend(uint32_t layer,
                                       const std::vector<float> & q,
                                       const std::vector<float> & k,
                                       const std::vector<float> & v) {
    // Qwen3 uses full query heads and fewer KV heads
    if (q.size() != uint64_t(shape_.n_head) * shape_.head_dim) throw std::runtime_error("attention q size mismatch");
    if (k.size() != uint64_t(shape_.n_head_kv) * shape_.head_dim) throw std::runtime_error("attention k size mismatch");
    if (v.size() != uint64_t(shape_.n_head_kv) * shape_.head_dim) throw std::runtime_error("attention v size mismatch");

    // Decode attention appends this token's K/V, then attends over the layer cache
    LayerCache & cache = kv_cache_.at(layer);
    cache.keys.push_back(k);
    cache.values.push_back(v);
    const uint64_t context = cache.keys.size();

    // core MAC counts for the attention accelerator target
    metrics_.attention_calls++;
    metrics_.attention_score_mac += uint64_t(shape_.n_head) * context * shape_.head_dim;
    metrics_.attention_value_mac += uint64_t(shape_.n_head) * context * shape_.head_dim;

    std::vector<float> out(uint64_t(shape_.n_head) * shape_.head_dim, 0.0f);
    std::vector<float> scores(context);
    const float scale = 1.0f / std::sqrt(float(shape_.head_dim));

    for (uint32_t head = 0; head < shape_.n_head; head++) {
      // Grouped-query attention maps multiple query heads to one KV head
      const uint32_t kv_head = head * shape_.n_head_kv / shape_.n_head;
      float max_score = -std::numeric_limits<float>::infinity();

      // Score pass: dot this query head against every cached key for the KV head
      for (uint64_t pos = 0; pos < context; pos++) {
        float score = 0.0f;
        for (uint32_t d = 0; d < shape_.head_dim; d++) {
          score += q[uint64_t(head) * shape_.head_dim + d] *
                   cache.keys[pos][uint64_t(kv_head) * shape_.head_dim + d];
        }
        scores[pos] = score * scale;
        max_score = std::max(max_score, scores[pos]);
      }

      // Softmax pass, subtracting max_score for numerical stability
      float denom = 0.0f;
      for (uint64_t pos = 0; pos < context; pos++) {
        scores[pos] = std::exp(scores[pos] - max_score);
        denom += scores[pos];
      }
      if (denom == 0.0f) throw std::runtime_error("attention softmax denominator is zero");

      // Value pass: weighted sum of cached values produces one output head
      for (uint64_t pos = 0; pos < context; pos++) {
        const float weight = scores[pos] / denom;
        for (uint32_t d = 0; d < shape_.head_dim; d++) {
          out[uint64_t(head) * shape_.head_dim + d] +=
              weight * cache.values[pos][uint64_t(kv_head) * shape_.head_dim + d];
        }
      }
    }
    return out;
  }

  std::vector<float> q1_matvec_backend(const std::string & tensor_name,
                                       const std::vector<float> & x,
                                       Q1Metrics & total,
                                       Q1Metrics * local = nullptr) {
    const TensorView & tensor = require_tensor(model_, tensor_name);
    if (tensor.type != GGUF_TYPE_Q1_0) throw std::runtime_error("Q1 backend expected Q1_0 tensor: " + tensor.name);
    if (tensor.dims.size() != 2) throw std::runtime_error("Q1 backend expected rank-2 tensor: " + tensor.name);

    const uint64_t cols = tensor.dims[0];
    const uint64_t rows = tensor.dims[1];
    if (x.size() != cols) throw std::runtime_error("Q1 backend input size mismatch: " + tensor.name);
    const uint64_t row_bytes = q1_0_row_size(cols);
    const std::vector<uint8_t> packed = read_q1_0_tensor(model_, tensor);

    // One call computes all output rows: rows dot products, each over cols packed weights.
    Q1Metrics call;
    call.calls = 1;
    call.rows = rows;
    call.dot_elements = rows * cols;
    call.groups_128 = rows * (cols / QK1_0);
    
    add_q1_metrics(total, call);
    if (local) add_q1_metrics(*local, call);

    std::vector<float> y(rows);
    for (uint64_t row = 0; row < rows; row++) {
      y[row] = dot_q1_0_row_f32(packed.data() + row * row_bytes, row_bytes, x);
    }
    return y;
  }

  void print_meta(const std::string & key) const {
    auto it = model_.meta.find(key);
    if (it != model_.meta.end()) std::cout << key << "=" << meta_to_string(it->second) << "\n";
  }

  ModelView model_;
  ModelShape shape_;
  BackendMetrics metrics_;
  DecodeMetrics decode_;
  std::vector<LayerCache> kv_cache_;
};


void print_metrics(const BackendMetrics & metrics, const DecodeMetrics & decode) {
  std::cout << "backend_metrics"
            << " decode_tokens=" << decode.tokens
            << " decode_layers=" << decode.layers
            << " decode_rms_norms=" << decode.rms_norms
            << " decode_q1_backend_calls=" << decode.q1_backend_calls
            << " decode_attention_backend_calls=" << decode.attention_backend_calls
            << " decode_residual_adds=" << decode.residual_adds
            << " decode_silu_gate_products=" << decode.silu_gate_products
            << " decode_lm_head_calls=" << decode.lm_head_calls
            << " transformer_q1_matvec_calls=" << metrics.transformer_q1.calls
            << " transformer_q1_rows=" << metrics.transformer_q1.rows
            << " transformer_q1_dot_elements=" << metrics.transformer_q1.dot_elements
            << " transformer_q1_groups_128=" << metrics.transformer_q1.groups_128
            << " attention_calls=" << metrics.attention_calls
            << " attention_score_mac=" << metrics.attention_score_mac
            << " attention_value_mac=" << metrics.attention_value_mac
            << " lm_head_q1_matvec_calls=" << metrics.lm_head_q1.calls
            << " lm_head_q1_rows=" << metrics.lm_head_q1.rows
            << " lm_head_q1_dot_elements=" << metrics.lm_head_q1.dot_elements
            << " lm_head_q1_groups_128=" << metrics.lm_head_q1.groups_128
            << "\n";
}
}

int main(int argc, char ** argv) 
{
  bonsai_tier2::RunConfig config;

  // Parse command-line arguments to identify config flags and model path
  try {
    config = bonsai_tier2::parse_args(argc, argv);
  } catch (const std::exception & e) {
    std::cerr << e.what() << "\n";
    return 2;
  }

  try {
    bonsai_tier2::ModelView model = bonsai_tier2::load_model_view(config.model_path);
    bonsai_tier2::ModelShape shape = bonsai_tier2::load_and_validate_shape(model);
    bonsai_tier2::Runner runner(std::move(model), shape);

    // Control runner behavior, based on config flags
    if (config.inspect_model) runner.inspect();
    if (config.check_q1) runner.check_q1();
    if (config.trace_one_token) {
      if (config.tokens.empty()) config.tokens.push_back(151643u);
      for (uint32_t token : config.tokens) runner.trace_one_token(token, config.top_k);
    }

    bonsai_tier2::print_metrics(runner.metrics(), runner.decode_metrics());
  } catch (const std::exception & e) {
    std::cerr << "error: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
