
ENV["CONTROL_ALGO_MOCK"] = "1"
mock_dir = @__DIR__
ENV["CONTROL_ALGO_MOCK_DIR"] = mock_dir

include("../Control_algorithm_v1.jl")

ENV["CONTROL_ALGO_MOCK"] = "0";