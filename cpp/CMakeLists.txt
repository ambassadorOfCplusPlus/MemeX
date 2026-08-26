cmake_minimum_required(VERSION 3.20)
project(memex_engine CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_library(memex_blob src/blob_loader.cpp src/layer_runtime.cpp src/kv_zones.cpp)
target_include_directories(memex_blob PUBLIC include)

# Drives the zoned context memory: where positions end up and what a token reads.
add_executable(memex_kv src/kv_bench.cpp)
target_link_libraries(memex_kv PRIVATE memex_blob)

# Checks the loader against the writer and proves the reads bypass the file cache.
add_executable(memex_blob_test src/blob_test.cpp)
target_link_libraries(memex_blob_test PRIVATE memex_blob)

add_library(memex_expert_cache src/expert_cache.cpp)
target_include_directories(memex_expert_cache PUBLIC include)

add_executable(memex_bench src/bench_replay.cpp)
target_link_libraries(memex_bench PRIVATE memex_expert_cache)

# Scores residency protocols against a recorded routing trace. Header-only
# policy, so it needs no link against the cache mechanism.
add_executable(memex_residency src/residency_sim.cpp)
target_include_directories(memex_residency PRIVATE include)

# Scores the adaptive-precision tier: how often reduced-precision weights are used
# while the task changes, and how fast full precision comes back.
add_executable(memex_precision src/precision_sim.cpp)
target_include_directories(memex_precision PRIVATE include)

if(MSVC)
  target_compile_options(memex_expert_cache PRIVATE /O2 /EHsc)
  target_compile_options(memex_blob PRIVATE /O2 /EHsc)
  target_compile_options(memex_blob_test PRIVATE /O2 /EHsc)
  target_compile_options(memex_kv PRIVATE /O2 /EHsc)
  target_compile_options(memex_bench PRIVATE /O2 /EHsc)
  target_compile_options(memex_residency PRIVATE /O2 /EHsc)
  target_compile_options(memex_precision PRIVATE /O2 /EHsc)
else()
  target_compile_options(memex_expert_cache PRIVATE -O2)
  target_compile_options(memex_blob PRIVATE -O2)
  target_compile_options(memex_blob_test PRIVATE -O2)
  target_compile_options(memex_kv PRIVATE -O2)
  target_link_libraries(memex_blob PUBLIC Threads::Threads)
  target_compile_options(memex_bench PRIVATE -O2)
  target_compile_options(memex_residency PRIVATE -O2)
  target_compile_options(memex_precision PRIVATE -O2)
  find_package(Threads REQUIRED)
  target_link_libraries(memex_expert_cache PUBLIC Threads::Threads)
endif()
