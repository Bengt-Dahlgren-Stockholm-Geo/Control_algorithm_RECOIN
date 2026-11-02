using Dates
using Plots
using DataFrames, CSV
gr()

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
const OUTPUT_FILE = "C:\\Silana\\Exchange\\SilanaOutputs.csv" # sensor readings, format: name;value per line
const INPUT_FILE = "C:\\Silana\\Exchange\\SilanaInputs.csv" # valve commands written by this program
const SELECTED_VARS_FILE = "selected_vars.csv" # optional: one variable name per line
const STOP_SIGNAL_FILE = "C:\\Silana\\Exchange\\SilanaStop.txt" # create this file to request a graceful stop
const READ_INTERVAL = 5.0 # seconds between output.csv reads
const SWITCH_INTERVAL = 300.0 # seconds between position changes
const STEP_DELAY = 30.0 # seconds to hold the "both open" safety state
const HISTORY_SECONDS = 3600.0 # how much history to keep for plotting (1 hour)

# Mock-mode controls for safe testing without touching physical exchange files.
# Set CONTROL_ALGO_MOCK=1 and optionally CONTROL_ALGO_MOCK_DIR=/path/to/mock.


const MOCK_ENV_KEY = "CONTROL_ALGO_MOCK"
const MOCK_DIR_ENV_KEY = "CONTROL_ALGO_MOCK_DIR"

# Target (valve_A, valve_B) state for each of the three positions.
# true = open, false = closed
const POSITIONS = Dict(
1 => (true, true), # both open
2 => (true, false), # A open, B closed
3 => (false, true), # A closed, B open
)

mutable struct ValveState
A::Bool
B::Bool
end

const SAFETY_RESET_SENT = Ref(false)
const DASHBOARD_HANDLE = Ref{Union{Nothing,Plots.Plot}}(nothing)

function mock_mode_enabled()
token = lowercase(strip(get(ENV, MOCK_ENV_KEY, "0")))
return token in ("1", "true", "yes", "on")
end

function exchange_file_path(filename::AbstractString, live_path::AbstractString)
    if mock_mode_enabled()
        mock_dir = get(ENV, MOCK_DIR_ENV_KEY, pwd())
        mkpath(mock_dir)
        return joinpath(mock_dir, filename)
    end
    return live_path
end

output_file_path() = OUTPUT_FILE #still fetching rela data even in mock-up mode
input_file_path() = exchange_file_path("SilanaInputs.csv", INPUT_FILE)
stop_signal_file_path() = exchange_file_path("SilanaStop.txt", STOP_SIGNAL_FILE)

# ---------------------------------------------------------------------------
# History buffers
# ---------------------------------------------------------------------------

# Rolling buffer of sensor readings. Variable names are not known in
# advance: whatever names appear in the first column of output.csv become
# keys of `series`, discovered on the fly. Every vector in `series` is kept
# the same length as `t`; a variable missing from a given read (or one that
# didn't exist yet for earlier reads) is padded with NaN so all series stay
# aligned to the same timeline for plotting.
mutable struct SensorHistory
t::Vector{DateTime}
series::Dict{String,Vector{Float64}}
end
SensorHistory() = SensorHistory(DateTime[], Dict{String,Vector{Float64}}())

function push_sample!(hist::SensorHistory, ts::DateTime, sample::Dict{String,Float64})
n = length(hist.t)

# Any brand-new variable name gets a fresh vector, backfilled with NaN
# for all the timestamps recorded before it first appeared.
for name in keys(sample)
if !haskey(hist.series, name)
hist.series[name] = fill(NaN, n)
end
end

push!(hist.t, ts)
for (name, vec) in hist.series
push!(vec, get(sample, name, NaN))
end
end

function trim_sensor_history!(hist::SensorHistory)
isempty(hist.t) && return
cutoff = now() - Millisecond(round(Int, HISTORY_SECONDS * 1000))
keep_from = findfirst(t -> t >= cutoff, hist.t)
if keep_from === nothing
empty!(hist.t)
for vec in values(hist.series)
empty!(vec)
end
elseif keep_from > 1
deleteat!(hist.t, 1:(keep_from - 1))
for vec in values(hist.series)
deleteat!(vec, 1:(keep_from - 1))
end
end
end

# Valve state history: fixed fields since there are always exactly two
# valves. Recorded on every write (including the intermediate safety step).
mutable struct ValveHistory
t::Vector{DateTime}
A::Vector{Int}
B::Vector{Int}
end
ValveHistory() = ValveHistory(DateTime[], Int[], Int[])

function trim_valve_history!(hist::ValveHistory)
isempty(hist.t) && return
cutoff = now() - Millisecond(round(Int, HISTORY_SECONDS * 1000))
keep_from = findfirst(t -> t >= cutoff, hist.t)
if keep_from === nothing
empty!(hist.t); empty!(hist.A); empty!(hist.B)
elseif keep_from > 1
deleteat!(hist.t, 1:(keep_from - 1))
deleteat!(hist.A, 1:(keep_from - 1))
deleteat!(hist.B, 1:(keep_from - 1))
end
end

function record_valve_state!(hist::ValveHistory, state::ValveState)
push!(hist.t, now())
push!(hist.A, state.A ? 1 : 0)
push!(hist.B, state.B ? 1 : 0)
trim_valve_history!(hist)
end

# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

# Writes input.csv in the format:
# valve_A;1
# valve_B;1
function write_valves(state::ValveState, valve_hist::ValveHistory)
open(input_file_path(), "w") do io
println(io, "KB04-SV521-CMD;", state.A ? 1 : 0)
println(io, "KB04-SV522-CMD;", state.B ? 1 : 0)
end
push!(valve_hist.t, now())
push!(valve_hist.A, state.A ? 1 : 0)
push!(valve_hist.B, state.B ? 1 : 0)
trim_valve_history!(valve_hist)
end

function write_default_valves!(valve_hist::Union{ValveHistory,Nothing}; reason::AbstractString="shutdown")
SAFETY_RESET_SENT[] && return
state = ValveState(POSITIONS[1]...)
try
if valve_hist === nothing
open(input_file_path(), "w") do io
println(io, "KB04-SV521-CMD;", state.A ? 1 : 0)
println(io, "KB04-SV522-CMD;", state.B ? 1 : 0)
end
else
write_valves(state, valve_hist)
end
SAFETY_RESET_SENT[] = true
println("[$(now())] Safety reset ($reason): KB04-SV521=1, KB04-SV522=1")
catch e
@error "Failed to write safety reset valves" exception=(e, catch_backtrace())
end
end

atexit(() -> write_default_valves!(nothing; reason="process exit"))

function stop_requested()
stop_file = stop_signal_file_path()
isfile(stop_file) || return false
try
token = lowercase(strip(read(stop_file, String)))
# Empty file counts as an explicit stop signal.
return isempty(token) || token in ("1", "true", "stop", "yes")
catch e
@warn "Could not read stop signal file, stopping for safety: $e"
return true
end
end

# Reads output.csv where each line is "name;value" (quotes around either
# field are tolerated). Any variable names are accepted -- nothing is
# hardcoded -- prints each one with a timestamp, and records the sample.
function read_and_print_outputs(sensor_hist::SensorHistory)
output_file = output_file_path()
if !isfile(output_file)
@warn "output.csv not found, skipping read"
return
end
try
sample = Dict{String,Float64}()
ts = now()
for raw_line in eachline(output_file)
# Strip whitespace, stray carriage returns, and a possible
# leading UTF-8 BOM so key matching is not thrown off by
# invisible characters.
line = strip(replace(raw_line, "\ufeff" => "", "\r" => ""))
isempty(line) && continue
parts = split(line, ';')
length(parts) < 2 && continue

name = strip(strip(parts[1]), '"')
raw_val = strip(strip(parts[2]), '"')
isempty(name) && continue

val = tryparse(Float64, raw_val)
if val === nothing
@warn "Could not parse value for $name: $raw_val"
continue
end

println("[$ts] $name = $val")
sample[name] = val
end

if !isempty(sample)
push_sample!(sensor_hist, ts, sample)
trim_sensor_history!(sensor_hist)
end
println("")
catch e
@warn "Error reading output.csv: $e"
end
end

# ---------------------------------------------------------------------------
# Variable selection (for the optional extra plot)
# ---------------------------------------------------------------------------

# Reads the list of variables to single out in a separate plot panel from
# SELECTED_VARS_FILE, one name per line, e.g.:
# T_in
# V
# (quotes around a name are tolerated, blank lines are ignored). Returns an
# empty vector -- meaning "no separate panel" -- if the file doesn't exist
# or has no valid entries. Re-read on every cycle, so editing the file
# while the program is running takes effect on the next redraw without a
# restart. Names don't need to exist yet in output.csv -- the panel simply
# shows nothing for a name until it starts appearing there.
function read_selected_variables()
isfile(SELECTED_VARS_FILE) || return String[]
try
names = String[]
for raw_line in eachline(SELECTED_VARS_FILE)
line = strip(replace(raw_line, "\ufeff" => "", "\r" => ""))
isempty(line) && continue
# Tolerate "name" or "name;" or "name;anything" -- only the
# first field is used.
name = strip(strip(split(line, ';')[1]), '"')
isempty(name) || push!(names, name)
end
return names
catch e
@warn "Error reading $SELECTED_VARS_FILE: $e"
return String[]
end
end

# ---------------------------------------------------------------------------
# Live plotting
# ---------------------------------------------------------------------------

function update_plot(sensor_hist::SensorHistory, valve_hist::ValveHistory, selected_vars::Vector{String})
if isempty(sensor_hist.t) && isempty(valve_hist.t)
return
end

p1 = plot(title="Sensor readings (last hour)", legend=:outertopright, xlabel="time", ylabel="value")
for name in sort(collect(keys(sensor_hist.series)))
plot!(p1, sensor_hist.t, sensor_hist.series[name], label=name)
end

p2 = plot(
title="Valve positions (last hour)",
legend=:outertopright,
xlabel="time",
ylim=(-0.15, 1.15),
yticks=([0, 1], ["closed", "open"]),
)
if !isempty(valve_hist.t)
plot!(p2, valve_hist.t, valve_hist.A, label="Valve A", seriestype=:steppost, linewidth=2)
plot!(p2, valve_hist.t, valve_hist.B, label="Valve B", seriestype=:steppost, linewidth=2)
end

if isempty(selected_vars)
plt = plot(p1, p2, layout=(2, 1), size=(950, 650), overwrite_figure=true)
if DASHBOARD_HANDLE[] === nothing
display(plt)
gui(plt)
else
display(plt)
end
DASHBOARD_HANDLE[] = plt
return
end

p3 = plot(title="Selected variables (last hour)", legend=:outertopright, xlabel="time", ylabel="value")
for name in selected_vars
if haskey(sensor_hist.series, name)
plot!(p3, sensor_hist.t, sensor_hist.series[name], label=name)
end
end

plt = plot(p1, p2, p3, layout=(3, 1), size=(950, 900), overwrite_figure=true)
if DASHBOARD_HANDLE[] === nothing
display(plt)
gui(plt)
else
display(plt)
end
DASHBOARD_HANDLE[] = plt
end

# ---------------------------------------------------------------------------
# Valve position logic
# ---------------------------------------------------------------------------

# Moves from `from_pos` to `to_pos`. Any transition touching position 1 is
# safe to apply directly (it never requires closing both valves at once).
# A 2<->3 transition is the dangerous case: naively flipping both booleans
# risks a brief state where both valves are closed and the path is
# occluded. To avoid that we always open the incoming valve first, then
# close the outgoing valve.
function apply_transition!(state::ValveState, from_pos::Int, to_pos::Int, valve_hist::ValveHistory; step_delay::Real=STEP_DELAY)
if (from_pos == 2 && to_pos == 3) || (from_pos == 3 && to_pos == 2)
if to_pos == 3
# Target: A closed, B open -> open B first, then close A
state.B = true
write_valves(state, valve_hist)
println("[$(now())] Step 1/2: open valve B (A still open)\n")
sleep(step_delay)

state.A = false
write_valves(state, valve_hist)
println("[$(now())] Step 2/2: close valve A -> position 3\n")
else
# Target: A open, B closed -> open A first, then close B
state.A = true
write_valves(state, valve_hist)
println("[$(now())] Step 1/2: open valve A (B still open)\n")
sleep(step_delay)

state.B = false
write_valves(state, valve_hist)
println("[$(now())] Step 2/2: close valve B -> position 2\n")
end
else
target_A, target_B = POSITIONS[to_pos]
state.A = target_A
state.B = target_B
write_valves(state, valve_hist)
println("[$(now())] Transition to position $to_pos: A=$(state.A ? 1 : 0), B=$(state.B ? 1 : 0)\n")
end
end

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

function main()
position = 1
state = ValveState(POSITIONS[1]...)
sensor_hist = SensorHistory()
valve_hist = ValveHistory()

write_valves(state, valve_hist)
println("[$(now())] Initial position 1: KB04-SV521=1, KB04-SV522=1")

last_read = time()
last_switch = time()
try
    while true


        if stop_requested()
            println("[$(now())] Stop requested via $(stop_signal_file_path()). Shutting down gracefully.")
            break
        end

    now_t = time()

    # println(valve_hist.A[end], " - ",valve_hist.B[end])

    if now_t - last_read >= READ_INTERVAL
        read_and_print_outputs(sensor_hist)
        record_valve_state!(valve_hist, state)
        selected_vars = read_selected_variables()
        update_plot(sensor_hist, valve_hist, selected_vars)
        last_read = now_t
    end

    if now_t - last_switch >= SWITCH_INTERVAL
        next_position = position == 3 ? 1 : position + 1
        apply_transition!(state, position, next_position, valve_hist)
        position = next_position
        last_switch = now_t
    end

    sleep(0.5)
    end
catch e
@error "Unhandled error in main loop" exception=(e, catch_backtrace())
finally
write_default_valves!(valve_hist; reason="main shutdown")
end
end

function should_autorun_main()
    # Direct script run: julia Control_algorithm_v1.jl
    if abspath(PROGRAM_FILE) == @__FILE__
        return true
    end

    # VS Code/REPL include() run: allow auto-run only in interactive Main.
    return isinteractive() && (@__MODULE__) == Main
end

if should_autorun_main()
    main()
end