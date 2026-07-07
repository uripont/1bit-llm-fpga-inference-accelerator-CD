// Pinned reference: external/llama.cpp at commit 1ec7ba0c14f33f17e980daeeda5f35b225d41994.
// Main source references to be used:
//   - external/llama.cpp/ggml/src/gguf.cpp                 GGUF container parsing
//   - external/llama.cpp/src/llama-model-loader.cpp        tensor metadata/loading path
//   - external/llama.cpp/src/models/qwen3.cpp              Qwen3 block graph
//   - external/llama.cpp/src/llama-kv-cache.cpp             KV-cache storage/update path
//   - external/llama.cpp/ggml/src/ggml-common.h            quantized block layouts
//   - external/llama.cpp/ggml/src/ggml-cpu/quants.c        Q1_0 CPU quant math
//   - external/llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c      CPU graph execution
//   - external/llama.cpp/ggml/src/ggml-blas/ggml-blas.cpp  BLAS matmul path used in Tier 1

#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

namespace bonsai_tier2 {

struct RunConfig {
  std::string model_path = "models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf";
  std::vector<uint32_t> tokens;

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
    } else if (arg == "--inspect-model") {
      config.inspect_model = true;
    } else if (arg == "--check-q1") {
      config.check_q1 = true;
    } else if (arg == "--trace-one-token") {
      config.trace_one_token = true;
    } else {
      throw std::runtime_error("usage: bonsai-explicit-runner [--model path] [--tokens id[,id...]] [--inspect-model] [--check-q1] [--trace-one-token]");
    }
  }
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
};

uint64_t align_to(uint64_t x, uint64_t alignment) {
  return ((x + alignment - 1) / alignment) * alignment;
}
std::string type_name(uint32_t type) {
  if (type == 0) return "f32";
  if (type == 1) return "f16";
  if (type == 41) return "q1_0";
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
// anchors: ggml-common.h, ggml-cpu/quants.c.
// TODO: add Q1_0 constants, row sizing, row dequant check
struct Q1Metrics {
  uint64_t calls = 0;
  uint64_t rows = 0;
  uint64_t dot_elements = 0;
  uint64_t groups_128 = 0;
};


// Future accelerator calls
struct BackendMetrics {
  Q1Metrics transformer_q1;
  Q1Metrics lm_head_q1;
  uint64_t attention_calls = 0;
  uint64_t attention_score_mac = 0;
  uint64_t attention_value_mac = 0;
};

// TODO: q1_matvec_backend(weight, x) -> y
// TODO: attention_backend(layer, q, kv_cache) -> y
// TODO: lm_head_backend(hidden) -> logits / argmax


// ---------------------------------------------------------------------------
// Bonsai/Qwen3 shape
// from models/qwen3.cpp and Bonsai GGUF metadata
// TODO: load from metadata, then assert Bonsai-1.7B expected dimensions

struct ModelShape {
  uint32_t n_layer = 0;
  uint32_t n_embd = 0;
  uint32_t n_ff = 0;
  uint32_t n_head = 0;
  uint32_t n_head_kv = 0;
  uint32_t head_dim = 0;
  uint32_t n_vocab = 0;
  float rms_eps = 0.0f;
};

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
      : model_(std::move(model)), shape_(shape) {}

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

  void trace_one_token(uint32_t token) {
    (void)token;
    // TODO: implement the order above one stage at a time
    std::cout << "trace_one_token=TODO\n";
  }

  void check_q1() {
    // TODO: compare Q1_0 helpers against simple dequantized references.
    std::cout << "check_q1=TODO\n";
  }

  const BackendMetrics & metrics() const { return metrics_; }

private:
  void print_meta(const std::string & key) const {
    auto it = model_.meta.find(key);
    if (it != model_.meta.end()) std::cout << key << "=" << meta_to_string(it->second) << "\n";
  }

  ModelView model_;
  ModelShape shape_;
  BackendMetrics metrics_;
};


void print_metrics(const BackendMetrics & metrics) {
  std::cout << "backend_metrics"
            << " transformer_q1_matvec_calls=" << metrics.transformer_q1.calls
            << " transformer_q1_rows=" << metrics.transformer_q1.rows
            << " transformer_q1_dot_elements=" << metrics.transformer_q1.dot_elements
            << " transformer_q1_groups_128=" << metrics.transformer_q1.groups_128
            << " attention_calls=" << metrics.attention_calls
            << " attention_score_mac=" << metrics.attention_score_mac
            << " attention_value_mac=" << metrics.attention_value_mac
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
    bonsai_tier2::ModelShape shape;
    bonsai_tier2::Runner runner(std::move(model), shape);

    // Control runner behavior, based on config flags
    if (config.inspect_model) runner.inspect();
    if (config.check_q1) runner.check_q1();
    if (config.trace_one_token) {
      const uint32_t token = config.tokens.empty() ? 151643u : config.tokens.front();
      runner.trace_one_token(token);
    }

    bonsai_tier2::print_metrics(runner.metrics());
  } catch (const std::exception & e) {
    std::cerr << "error: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
