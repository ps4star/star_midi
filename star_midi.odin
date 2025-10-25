package star_midi
import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:slice"
import "core:mem"
import "core:time"
import "core:os"
import "core:encoding/json"

// STAR_MIDI
// Tiny Odin-language MIDI parsing library
// Supports all-at-once parsing as well as parse-on-the-fly

// Set to f32 for 32-bit
Float :: f64

Error_Code :: enum {
    NONE = 0,
    FILE_IO_ERROR,

    MIDI_MISSING_HEADER,
    MIDI_INVALID_HEADER_LENGTH,
    MIDI_INVALID_FORMAT,
    MIDI_INVALID_DELTA_TIMING,
    MIDI_NO_TRACKS,
    MIDI_MORE_TRACKS_THAN_EXPECTED,
    MIDI_INVALID_VLQ,
    MIDI_MISSING_SYSEX_TERMINATOR,
    MIDI_UNKNOWN_META_EVENT,
    MIDI_EXHAUSTED_TRACKS,

    DUMP_UNKNOWN_FORMAT,
}

MIDI_Format :: enum u16be { // Parity with actual midi spec
    SINGLE_TRACK = 0,
    MULTI_TRACK = 1,
    MULTI_SONG = 2,
}

MIDI_NoteOffEvent :: struct { channel, key, velocity: u8, }
MIDI_NoteOnEvent :: struct { channel, key, velocity: u8, }
MIDI_PolyphonicKeyPressureEvent :: struct { channel, key, velocity: u8, }
MIDI_ControlChangeEvent :: struct { channel, controller_number, new_value: u8, }
MIDI_ProgramChangeEvent :: struct { channel, new_program_number: u8, }
MIDI_ChannelPressureEvent :: struct { channel, pressure_value: u8, }
MIDI_PitchWheelChangeEvent :: struct { channel: u8, pitch_change: u16, }
MIDI_ChannelModeMessageEvent :: struct { channel, cc, vv: u8 }
MIDI_TuneRequestEvent :: struct {}
MIDI_TimingClockEvent :: struct {}
MIDI_StartSequenceEvent :: struct {}
MIDI_ContinueSequenceEvent :: struct {}
MIDI_StopSequenceEvent :: struct {}
MIDI_ActiveSensingEvent :: struct {}
MIDI_SequenceNumberEvent :: struct { seq_num: u8 }
MIDI_SetTempoEvent :: struct { microseconds_per_quarter_note: u32, }
MIDI_EndOfTrackEvent :: struct {}
MIDI_SysexEvent :: struct { message: []u8, }
MIDI_TextEvent :: struct { message: string, }
MIDI_ChannelPrefixEvent :: struct { channel_prefix: u8, }
MIDI_SetSMPTEOffsetEvent :: struct { smpte_offset: [5]u8, }
MIDI_TimeSignatureEvent :: struct { numerator, denominator, clocks_per_metronome, thirty_second_notes_per_quarter: u8 }
MIDI_KeySignatureEvent :: struct { sharps_or_flats: i8, major_or_minor: u8, }

MIDI_DEPRECATED_ChannelEvent :: struct { channel: u8, }
MIDI_DEPRECATED_PortEvent :: struct { port: u8, }

MIDI_EventUnion :: union {
    MIDI_NoteOffEvent,
    MIDI_NoteOnEvent,
    MIDI_PolyphonicKeyPressureEvent,
    MIDI_ControlChangeEvent,
    MIDI_ProgramChangeEvent,
    MIDI_ChannelPressureEvent,
    MIDI_PitchWheelChangeEvent,
    MIDI_ChannelModeMessageEvent,
    MIDI_TuneRequestEvent,
    MIDI_TimingClockEvent,
    MIDI_StartSequenceEvent,
    MIDI_ContinueSequenceEvent,
    MIDI_StopSequenceEvent,
    MIDI_ActiveSensingEvent,
    MIDI_SequenceNumberEvent,
    MIDI_SetTempoEvent,
    MIDI_EndOfTrackEvent,
    MIDI_SysexEvent,
    MIDI_TextEvent,
    MIDI_ChannelPrefixEvent,
    MIDI_SetSMPTEOffsetEvent,
    MIDI_TimeSignatureEvent,
    MIDI_KeySignatureEvent,

    MIDI_DEPRECATED_ChannelEvent,
    MIDI_DEPRECATED_PortEvent,
}

MIDI_Event :: struct {
    time: Float,
    variant: MIDI_EventUnion,
}

MIDI :: struct {
    src: []byte,
    src_ptr: int,
    past_header_ptr: int,
    track_ptrs, initial_track_ptrs: []int,

    midi_format: MIDI_Format,
    num_tracks_expected: int,

    absolute_clock: Float,
    next_event_clocks: []Float, // <num_track>-sized list

    // Parsing output caches
    realtime_cache: [][dynamic]MIDI_Event,

    // Tempo
    delta_timing: int,
    microseconds_per_tick: int,
    tick_length_microseconds: Float,

    running_status: u8,
    allocator: runtime.Allocator,
}

@private seek_until_chunk_title :: proc "fastcall" (this: ^MIDI, target: [4]u8) -> (bool) {
    assert_contextless(this != nil)
    target := target
    for this.src_ptr+4 < len(this.src) {
        if mem.compare(target[:], this.src[this.src_ptr:this.src_ptr+4]) == 0 {
            this.src_ptr += 4
            return true
        }
        this.src_ptr += 1
    }
    return false
}

@private seek_until_byte :: proc(this: ^MIDI, b: byte) -> (bool) {
    assert(this != nil)
    old_ptr := this.src_ptr
    idx, found := slice.linear_search(this.src[this.src_ptr:], b)
    if !found {
        return false
    }
    this.src_ptr = old_ptr + idx + 1
    return true
}

// Consumes an int from the midi file of specified type
@private consume_int :: proc(this: ^MIDI, $T: typeid) -> (T) {
    #assert(intrinsics.type_is_integer(T))
    assert(this != nil)
    raw := this.src[this.src_ptr:this.src_ptr + size_of(T)]; this.src_ptr += size_of(T)
    return (^T)(raw_data(raw))^
}

// Same as consume_int() but does not advance parser's cursor
@private peek_int :: proc(this: ^MIDI, $T: typeid) -> (T) {
    out := consume_int(this, T); this.src_ptr -= size_of(T)
    return out
}

// Consume a MIDI Variable-Length Quantity (this is really stupid)
// If a byte's 7-bit is set, the next byte is also part of the number
@private consume_vlq :: proc "fastcall" (this: ^MIDI) -> (out: int, err: Error_Code) {
    assert_contextless(this != nil)
    out = 0
    for {
        this_byte := int(this.src[this.src_ptr]); this.src_ptr += 1
        data_bits := this_byte & 0b0111_1111
        out |= data_bits
        if this_byte & 0b1000_0000 > 0 {
            out <<= 7
        } else {
            return out, .NONE
        }
    }
    return 0, .MIDI_INVALID_VLQ
}

@private peek_vlq :: proc "fastcall" (this: ^MIDI) -> (out: int, err: Error_Code) {
    old := this.src_ptr
    out, err = consume_vlq(this)
    this.src_ptr = old
    return
}

@private midi_time_to_seconds :: proc(this: ^MIDI, midi_time: int) -> (Float) {
    assert(this != nil)
    return Float(midi_time) * (Float(this.microseconds_per_tick) / 1_000_000) / Float(this.delta_timing)
}

@private consume_event :: proc(this: ^MIDI) -> (ev: MIDI_Event, err: Error_Code) {
    assert(this != nil)
    t_before, t_err := consume_vlq(this)
    if t_err != .NONE {
        return {variant = nil}, t_err
    }
    ev.time = Float(midi_time_to_seconds(this, t_before))

    next_byte := this.src[this.src_ptr]
    next_hi_part := (next_byte & 0b1111_0000) >> 4
    if next_hi_part >= 0b1000 && next_hi_part <= 0b1110 {
        this.running_status = consume_int(this, u8)
    } else if next_byte >= 0xF0 {
        this.src_ptr += 1
        beginning_ptr := this.src_ptr
        if next_byte == 0xF0 || next_byte == 0xF7 {
            if !seek_until_byte(this, 0xF7) { // Ignore message
                return {variant = nil}, .MIDI_MISSING_SYSEX_TERMINATOR
            }
            ev.variant = MIDI_SysexEvent{
                message = new_clone(this.src[beginning_ptr:this.src_ptr-1], this.allocator)^,
            }
        } else if next_byte == 0xF1 {
            // Undefined, NOP
        } else if next_byte == 0xF2 {
            // Song pos. ptr
            lsb := consume_int(this, u8)
            msb := consume_int(this, u8)
        } else if next_byte == 0xF3 {
            // Song id
            song_id := consume_int(this, u8)
            _ = song_id
        } else if next_byte == 0xF4 {
            // Undefined, NOP
        } else if next_byte == 0xF5 {
            // Undefined, NOP
        } else if next_byte == 0xF6 {
            // Tune Request
            ev.variant = MIDI_TuneRequestEvent{}
        } else if next_byte == 0xF8 {
            // Timing clock
            ev.variant = MIDI_TimingClockEvent{}
        } else if next_byte == 0xF9 {
            // Undefined, NOP
        } else if next_byte == 0xFA {
            // Start Sequence
            ev.variant = MIDI_StartSequenceEvent{}
        } else if next_byte == 0xFB {
            ev.variant = MIDI_ContinueSequenceEvent{}
        } else if next_byte == 0xFC {
            ev.variant = MIDI_StopSequenceEvent{}
        } else if next_byte == 0xFD {
            // Undefined, NOP
        } else if next_byte == 0xFE {
            // Active Sensing
            ev.variant = MIDI_ActiveSensingEvent{}
        } else if next_byte == 0xFF {
            // Escape into a meta-event
            // 00 02 -> Sequence Number
            if this.src[this.src_ptr] == 0x00 {
                consume_int(this, u8)
                if this.src[this.src_ptr] != 0x02 {
                    return {variant = nil}, .MIDI_UNKNOWN_META_EVENT
                }
                consume_int(this, u8)
                seq_num := consume_int(this, u8) // Sequence number
                ev.variant = MIDI_SequenceNumberEvent{
                    seq_num = seq_num,
                }
            } else if (this.src[this.src_ptr] >= 0x01 && this.src[this.src_ptr] <= 0x07) || this.src[this.src_ptr] == 0x7F {
                // Some kind of text event that we can skip
                consume_int(this, u8)
                text_len, v_err := consume_vlq(this)
                text_start_ptr := this.src_ptr
                this.src_ptr += int(text_len)
                ev.variant = MIDI_TextEvent{
                    message = new_clone(cast(string) this.src[text_start_ptr:this.src_ptr], this.allocator)^,
                }
            } else if this.src[this.src_ptr] == 0x20 {
                consume_int(this, u8)
                if this.src[this.src_ptr] != 0x01 {
                    return {variant = nil}, .MIDI_UNKNOWN_META_EVENT
                }
                consume_int(this, u8)
                c_prefix := consume_int(this, u8) // MIDI channel prefix
                ev.variant = MIDI_ChannelPrefixEvent{
                    channel_prefix = c_prefix,
                }
            } else if this.src[this.src_ptr] == 0x2F {
                // END OF TRACK EVENT
                consume_int(this, u8) // skip 0x2F
                if this.src[this.src_ptr] != 0x00 {
                    return {variant = nil}, .MIDI_UNKNOWN_META_EVENT
                }
                consume_int(this, u8) // skip 0x00
                ev.variant = MIDI_EndOfTrackEvent{}
            } else if this.src[this.src_ptr] == 0x51 {
                consume_int(this, u8)
                if this.src[this.src_ptr] != 0x03 {
                    return {variant = nil}, .MIDI_UNKNOWN_META_EVENT
                }
                consume_int(this, u8)
                byte_2 := u32(consume_int(this, u8))
                byte_1 := u32(consume_int(this, u8))
                byte_0 := u32(consume_int(this, u8))
                final_val := (byte_2 << 16) | (byte_1 << 8) | byte_0
                this.microseconds_per_tick = int(Float(final_val))
                sync_tempo(this)
                ev.variant = MIDI_SetTempoEvent{
                    microseconds_per_quarter_note = final_val,
                }
            } else if this.src[this.src_ptr] == 0x54 {
                // Set SMPTE Offset
                consume_int(this, u8)
                if this.src[this.src_ptr] != 0x05 {
                    return {variant = nil}, .MIDI_UNKNOWN_META_EVENT
                }
                consume_int(this, u8)
                hr := consume_int(this, u8)
                mn := consume_int(this, u8)
                se := consume_int(this, u8)
                fr := consume_int(this, u8)
                ff := consume_int(this, u8)
                ev.variant = MIDI_SetSMPTEOffsetEvent{
                    smpte_offset = {hr, mn, se, fr, ff},
                }
            } else if this.src[this.src_ptr] == 0x58 {
                consume_int(this, u8)
                if this.src[this.src_ptr] != 0x04 {
                    return {variant = nil}, .MIDI_UNKNOWN_META_EVENT
                }
                consume_int(this, u8)
                nn := consume_int(this, u8)
                dd := consume_int(this, u8)
                cc := consume_int(this, u8)
                bb := consume_int(this, u8)
                ev.variant = MIDI_TimeSignatureEvent{
                    numerator = nn,
                    denominator = dd,
                    clocks_per_metronome = cc,
                    thirty_second_notes_per_quarter = bb,
                }
            } else if this.src[this.src_ptr] == 0x59 {
                // Key signature event
                consume_int(this, u8)
                if this.src[this.src_ptr] != 0x02 {
                    return {variant = nil}, .MIDI_UNKNOWN_META_EVENT
                }
                consume_int(this, u8)
                sf := consume_int(this, i8)
                mi := consume_int(this, u8)
                ev.variant = MIDI_KeySignatureEvent{
                    sharps_or_flats = sf,
                    major_or_minor = mi,
                }
            } else if this.src[this.src_ptr] == 0x20 {
                // DEPRECATED: MIDI channel
                consume_int(this, u16)
                cc := consume_int(this, u8) // cc
                ev.variant = MIDI_DEPRECATED_ChannelEvent{
                    channel = cc,
                }
            } else if this.src[this.src_ptr] == 0x21 {
                // DEPRECATED: MIDI port
                consume_int(this, u16)
                pp := consume_int(this, u8) // pp
                ev.variant = MIDI_DEPRECATED_PortEvent{
                    port = pp,
                }
            }
        }
        if ev.variant == nil {
            fmt.println("NIL VAR", this.src_ptr)
        }
        return
    }

    // Channel messages
    hi_part := (this.running_status & 0b1111_0000) >> 4
    lo_part := (this.running_status & 0b0000_1111)
    if hi_part == 0b1000 {
        // Note off event
        kk := consume_int(this, u8)
        vv := consume_int(this, u8)
        ev.variant = MIDI_NoteOffEvent{
            channel = lo_part,
            key = kk,
            velocity = vv,
        }
    } else if hi_part == 0b1001 {
        // Note on event
        kk := consume_int(this, u8)
        vv := consume_int(this, u8)
        ev.variant = MIDI_NoteOnEvent{
            channel = lo_part,
            key = kk,
            velocity = vv,
        }
    } else if hi_part == 0b1010 {
        // Polyphonic key pressure
        kk := consume_int(this, u8)
        vv := consume_int(this, u8)
        ev.variant = MIDI_PolyphonicKeyPressureEvent{
            channel = lo_part,
            key = kk,
            velocity = vv,
        }
    } else if hi_part == 0b1011 {
        // Control Change
        cc := consume_int(this, u8)
        vv := consume_int(this, u8)
        ev.variant = MIDI_ControlChangeEvent{
            channel = lo_part,
            controller_number = cc,
            new_value = vv,
        }
    } else if hi_part == 0b1100 {
        // Program Change
        pp := consume_int(this, u8)
        ev.variant = MIDI_ProgramChangeEvent{
            channel = lo_part,
            new_program_number = pp,
        }
    } else if hi_part == 0b1101 {
        // Channel Pressure
        vv := consume_int(this, u8)
        ev.variant = MIDI_ChannelPressureEvent{
            channel = lo_part,
            pressure_value = vv,
        }
    } else if hi_part == 0b1110 {
        // Pitch Wheel
        lsb := consume_int(this, u8)
        msb := consume_int(this, u8)
        final_val := u16(lsb & 0x7F) | (u16(msb & 0x7F) << 7)
        ev.variant = MIDI_PitchWheelChangeEvent{
            channel = lo_part,
            pitch_change = final_val,
        }
    }
    if ev.variant == nil {
            fmt.println("NIL VAR", this.src_ptr)
        }
    return
}

// Call this after you modify tempo
@private sync_tempo :: proc(this: ^MIDI) {
    assert(this != nil)
    this.tick_length_microseconds = Float(this.microseconds_per_tick) / Float(this.delta_timing)
}

// Sets up parser state and points it to the MIDI file for parsing
init_from_memory :: proc(this: ^MIDI, src: []byte, allocator := context.allocator) -> (Error_Code) {
    assert(this != nil)
    this^ = {}
    this.allocator = allocator
    this.src = src

    this.microseconds_per_tick = 500_000 // Default value until set by meta event

    // Go ahead and grab "MThd" chunk data up front
    if !seek_until_chunk_title(this, { 'M', 'T', 'h', 'd' }) {
        return .MIDI_MISSING_HEADER
    }
    header_length := consume_int(this, u32be)
    if header_length != 6 { // This should always be 6; if not, something is wrong
        return .MIDI_INVALID_HEADER_LENGTH
    }
    specified_fmt := consume_int(this, u16be)
    if specified_fmt < 0 || specified_fmt > 2 {
        return .MIDI_INVALID_FORMAT
    }
    this.midi_format = MIDI_Format(specified_fmt)
    tracks_expected := consume_int(this, u16be)
    if tracks_expected == 0 {
        return .MIDI_NO_TRACKS
    }
    this.num_tracks_expected = cast(int) tracks_expected

    // Handle delta time value
    delta_timing := consume_int(this, u16be)
    if delta_timing == 0 {
        return .MIDI_INVALID_DELTA_TIMING
    }
    if delta_timing & 0x8000 == 0 {
        // Ticks per beat method
        this.delta_timing = int(delta_timing)
        sync_tempo(this)
    } else {
        // SMPTE timing method
        hi_value := (delta_timing & 0b0111_1111__0000_0000) >> 8
        lo_value := (delta_timing & 0b0000_0000__1111_1111)
        if hi_value > 30 || hi_value < 24 || (hi_value > 25 && hi_value < 29) {
            return .MIDI_INVALID_DELTA_TIMING
        }

        calc_hi_value: Float
        if hi_value == 29 { // "29" is actually 29.97
            calc_hi_value = 29.97
        } else {
            calc_hi_value = Float(hi_value)
        }
        this.tick_length_microseconds = Float(1_000_000) / (calc_hi_value * Float(lo_value))
        sync_tempo(this)
    }
    this.past_header_ptr = this.src_ptr // Points to first "MTrk" in the file

    // Setup our individual track ptrs by scanning file
    this.track_ptrs = make([]int, this.num_tracks_expected, allocator)
    this.initial_track_ptrs = make([]int, this.num_tracks_expected, allocator)
    this.next_event_clocks = make([]Float, this.num_tracks_expected, allocator)
    for i in 0..<this.num_tracks_expected {
        if !seek_until_chunk_title(this, { 'M', 'T', 'r', 'k' }) {
            return .MIDI_MORE_TRACKS_THAN_EXPECTED
        }
        _ = consume_int(this, u32)
        this.track_ptrs[i] = this.src_ptr
        this.initial_track_ptrs[i] = this.src_ptr
        this.next_event_clocks[i] = 0.0
    }
    this.src_ptr = this.past_header_ptr
    return .NONE
}

// Just a wrapper around *_from_memory
init :: proc(this: ^MIDI, fullpath: string, allocator := context.allocator) -> (Error_Code) {
    assert(this != nil)
    f_data, ok := os.read_entire_file_from_filename(fullpath, allocator)
    if !ok {
        return .FILE_IO_ERROR
    }
    return init_from_memory(this, f_data, allocator)
}

// Parses the file in REAL-TIME (in seconds)
// Pass in the number of seconds you want the parser to advance,
// and it will return a num_tracks-sized list containing lists of MIDI events that were
// 'fired' during the given time interval
parse_realtime :: proc(this: ^MIDI, seconds: Float, allocator := context.allocator, no_alloc := false) -> ([][dynamic]MIDI_Event, Error_Code) {
    assert(this != nil)
    cur_track := 0

    if !no_alloc {
        if this.realtime_cache == nil {
            this.realtime_cache = make([][dynamic]MIDI_Event, this.num_tracks_expected, allocator)
            for cur_track in 0..<this.num_tracks_expected {
                this.realtime_cache[cur_track] = make([dynamic]MIDI_Event, 0, 64, allocator)
            }
        } else {
            for cur_track in 0..<this.num_tracks_expected {
                clear(&this.realtime_cache[cur_track])
            }
        }
    }

    // If we've already exhausted all tracks in the MIDI, return nil
    num_valid_tracks := 0
    for p in this.track_ptrs {
        if p >= 0 {
            num_valid_tracks += 1
        }
    }
    if num_valid_tracks <= 0 {
        return nil, .MIDI_EXHAUSTED_TRACKS
    }

    this.absolute_clock += seconds
    for cur_track < this.num_tracks_expected {
        if this.track_ptrs[cur_track] < 0 {
            cur_track += 1
            continue
        }
        this.next_event_clocks[cur_track] += seconds
        this.src_ptr = this.track_ptrs[cur_track]

        // Keep pulling events from the track until 
        for {
            // fmt.println("PEEK VLQ", this.src_ptr)
            time_before_next_event, err := peek_vlq(this)
            if err != .NONE {
                return nil, err
            }
            time_in_seconds := midi_time_to_seconds(this, time_before_next_event)
            if this.next_event_clocks[cur_track] >= time_in_seconds {
                // Fire event
                ev, ev_err := consume_event(this)
                ev.time = clamp((this.next_event_clocks[cur_track] - time_in_seconds) / seconds, 0, 1)
                if ev_err != .NONE {
                    return nil, ev_err
                }
                if !no_alloc { append(&this.realtime_cache[cur_track], ev) }
                if _, is_track_event := ev.variant.(MIDI_EndOfTrackEvent); is_track_event {
                    // Invalidate track
                    this.track_ptrs[cur_track] = -1
                    break
                }
                this.next_event_clocks[cur_track] -= time_in_seconds
            } else {
                break
            }
        }
        if this.track_ptrs[cur_track] >= 0 { // Prevent writing if invalid
            this.track_ptrs[cur_track] = this.src_ptr
        }
        cur_track += 1
    }
    return this.realtime_cache, .NONE
}

// Goes through the entire file from the beginning;
// returns a list of all events from all tracks
parse_entire_file :: proc(this: ^MIDI, allocator := context.allocator) -> ([][dynamic]MIDI_Event, Error_Code) {
    assert(this != nil && len(this.src) > 0)

    seek(this, 0)
    cur_track := 0
    out := make([][dynamic]MIDI_Event, this.num_tracks_expected, allocator)
    for this.src_ptr < len(this.src) {
        if !seek_until_chunk_title(this, { 'M', 'T', 'r', 'k' }) {
            seek(this, 0)
            return nil, .MIDI_NO_TRACKS
        }

        out[cur_track] = make([dynamic]MIDI_Event, 0, 512, allocator)
        if cur_track > this.num_tracks_expected {
            seek(this, 0)
            return nil, .MIDI_MORE_TRACKS_THAN_EXPECTED
        }
        bytes_after_this := cast(int) consume_int(this, u32be)
        begin_track_src_ptr := this.src_ptr

        for this.src_ptr < (begin_track_src_ptr + bytes_after_this) {
            fmt.println("PEEK VLQ", this.src_ptr)
            if true{os.exit(0)}
            ev, ev_err := consume_event(this)
            if ev_err != .NONE {
                seek(this, 0)
                return nil, ev_err
            }
            append(&out[cur_track], ev)
            if _, is_track_event := ev.variant.(MIDI_EndOfTrackEvent); is_track_event {
                break
            }
        }
        cur_track += 1
    }
    seek(this, 0)
    return out, .NONE
}

seek :: proc(this: ^MIDI, offset: Float) {
    assert(this != nil)
    this.src_ptr = this.past_header_ptr
    this.absolute_clock = 0.0
    for &nec in this.next_event_clocks { nec = 0.0 }
    for &p, i in this.track_ptrs { p = this.initial_track_ptrs[i] }

    if offset > 0 {
        parse_realtime(this, offset, no_alloc=true)
    }
}

rewind :: proc(this: ^MIDI, offset: Float) {
    assert(this != nil)
    seek(this, this.absolute_clock - offset)
}

dump_json :: proc(data: [][dynamic]MIDI_Event, path: string, allocator := context.temp_allocator) {
    data, marshal_err := json.marshal(data, { pretty = true, use_enum_names = true, }, allocator)
    if data != nil {
        if os.exists(path) {
            os.unlink(path)
        }
        os.write_entire_file(path, data)
    }
}