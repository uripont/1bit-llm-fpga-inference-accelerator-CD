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
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
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


// Parsing helpers for bools in config
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

// TODO: parse only the GGUF fields needed by Bonsai Q1_0
struct TensorView {
  std::string name;
  std::vector<uint64_t> dims;
  uint32_t type = 0;
};

struct ModelView {
  std::vector<TensorView> tensors;
};

ModelView load_model_view(const std::string & model_path) {
  (void)model_path;
  return {}; // TODO
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
    std::cout << "tensor_count=" << model_.tensors.size() << "\n";
    for (const TensorView & tensor : model_.tensors) {
      std::cout << tensor.name << " dims=" << tensor.dims.size()
                << " type=" << tensor.type << "\n";
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
  return 0;
}
