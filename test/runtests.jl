using Test

ENV["CONTROL_ALGO_MOCK"] = "1"
mock_dir = mktempdir()
ENV["CONTROL_ALGO_MOCK_DIR"] = mock_dir

include(joinpath(@__DIR__, "..", "Control_algorithm_v1.jl"))

@testset "Control algorithm mock environment" begin
    @test mock_mode_enabled()

    @testset "Valve writes go to mock exchange" begin
        hist = ValveHistory()
        state = ValveState(false, true)
        write_valves(state, hist)

        path = input_file_path()
        @test isfile(path)
        content = read(path, String)
        @test occursin("KB04-SV521-CMD;0", content)
        @test occursin("KB04-SV522-CMD;1", content)
        @test length(hist.t) == 1
    end

    @testset "Stop signal file handling" begin
        stop_path = stop_signal_file_path()
        isfile(stop_path) && rm(stop_path)
        @test !stop_requested()

        write(stop_path, "stop")
        @test stop_requested()

        write(stop_path, "")
        @test stop_requested()
    end

    @testset "Safety reset writes default once" begin
        hist = ValveHistory()
        SAFETY_RESET_SENT[] = false

        write_default_valves!(hist; reason="test reset")
        first_len = length(hist.t)
        @test first_len == 1

        content = read(input_file_path(), String)
        @test occursin("KB04-SV521-CMD;1", content)
        @test occursin("KB04-SV522-CMD;1", content)

        write_default_valves!(hist; reason="second reset should no-op")
        @test length(hist.t) == first_len
    end

    @testset "Output parsing in mock mode" begin
        sensor_hist = SensorHistory()
        out_path = output_file_path()

        open(out_path, "w") do io
            println(io, "T_in;22.5")
            println(io, "V;3.0")
            println(io, "bad_line")
        end

        read_and_print_outputs(sensor_hist)
        @test length(sensor_hist.t) == 1
        @test haskey(sensor_hist.series, "T_in")
        @test haskey(sensor_hist.series, "V")
        @test sensor_hist.series["T_in"][end] == 22.5
        @test sensor_hist.series["V"][end] == 3.0
    end

    @testset "Transition logic (no wait in test)" begin
        hist = ValveHistory()
        state = ValveState(true, false)
        apply_transition!(state, 2, 3, hist; step_delay=0)
        @test state.A == false
        @test state.B == true
        @test length(hist.t) == 2
    end
end
