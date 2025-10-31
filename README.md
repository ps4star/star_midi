# star_midi.odin

Simple MIDI file parser in Odin.

## Usage

Copy/paste `star_midi.odin` into your project to use it. Make sure it's in its own folder so that it's recognized as a separate module.

## API

This library contains only __eight__ procs, which should cover most things you'd want to do with MIDI.

`init(^MIDI, full_path_of_file)` - Initailizes MIDI from file

```odin
import sm "./star_midi"

parser: sm.MIDI

main :: proc() {
    midi_path := "./test.mid"
    err_code := sm.init(&parser, midi_path)
    assert(err_code == .NONE)

    // Our file is now loaded and ready for processing
    // ...
}
```

`init_from_memory(^MIDI, data)` - Initializes MIDI from memory

```odin
import sm "./star_midi"

parser: sm.MIDI

main :: proc() {
    midi_mem :: #load("./test.mid", []u8)
    err_code := sm.init_from_memory(&parser, midi_mem)
    assert(err_code == .NONE)

    // Our file is now loaded and ready for processing
    // ...
}
```

`parse_realtime(^MIDI, seconds_to_process)` - Advance parser state by specified amount of time and return events fired during the interval

NOTE: The "time" field when using parse_realtime represents a __completely different value__ than in entire_file mode.
In parse_realtime, it is a fraction of the `seconds` value you passed to the proc
E.g. if the current clock time is 5, `seconds=3`, but the next event is only 1 second away, then `time=0.333334`

```odin
import sm "./star_midi"

parser: sm.MIDI

main :: proc() {
    // ...
    // Assume we've already called parser_init*(&parser...)

    data, err_code := sm.parse_realtime(&parser, 0.016)
    assert(err_code == .NONE)
    // Returns [][dynamic]MIDI_Event of everything that's happened on all tracks during the 0.016-second interval (1 frame @60FPS)
    // data[n] will be [] if no events happened on track n during the interval
    // Also it caches its memory allocation here so you cannot call free() in between usages, only after you're done
}
```

`parse_entire_file(^MIDI)` - Parse entire file at once

```odin
import sm "./star_midi"

parser: sm.MIDI

main :: proc() {
    // ...
    // Assume we've already called parser_init*(&parser...)

    data, err_code := sm.parse_entire_file(&parser)
    assert(err_code == .NONE)
}
```

`seek(^MIDI, seek_to)` - Seeks to a given offset from beginning of file

```odin
import sm "./star_midi"

parser: sm.MIDI

main :: proc() {
    // ...
    // Assume we've already called parser_init*(&parser...)

    // Grab first 10 seconds of data
    data, err_code := sm.parse_realtime(&parser, 10)
    assert(err_code == .NONE)

    // Go back
    sm.seek(&parser, 0)

    // Grab first 3 seconds of data from beginning again
    data, err_code = sm.parse_realtime(&parser, 3)
    assert(err_code == .NONE)
}
```

`fast_forward(^MIDI, offset_from_now)` - Seeks to a given offset from current position

```odin
import sm "./star_midi"

parser: sm.MIDI

main :: proc() {
    // ...
    // Assume we've already called parser_init*(&parser...)

    // Grab first 10 seconds of data
    data, err_code := sm.parse_realtime(&parser, 10)
    assert(err_code == .NONE)

    // Jump ahead by 5 seconds
    sm.fast_forward(&parser, 5)

    // Grab the next 3 seconds
    data, err_code = sm.parse_realtime(&parser, 3)
    assert(err_code == .NONE)
}
```

`rewind(^MIDI, rewind_by)` - Seeks backwards from current spot by given offset

```odin
import sm "./star_midi"

parser: sm.MIDI

main :: proc() {
    // ...
    // Assume we've already called parser_init*(&parser...)

    // Grab first 10 seconds of data
    data, err_code := sm.parse_realtime(&parser, 10)
    assert(err_code == .NONE)

    // Rewind by 5 seconds (we're at the 5 second mark)
    sm.rewind(&parser, 5)

    // Grab the next 3 seconds
    data, err_code = sm.parse_realtime(&parser, 3)
    assert(err_code == .NONE)
}
```

`dump_json([][dynamic]MIDI_Event, out_file_name)` - Useful utility proc for dumping `parse_entire_file` results

```odin
import sm "./star_midi"

parser: sm.MIDI

main :: proc() {
    // ...
    // Assume we've already called parser_init*(&parser...)

    data, err_code := sm.parse_entire_file(&parser, context.allocator)
    assert(err_code == .NONE)
    sm.dump_json(data, "dump.json")
}
```

## Performance

Tested with 100KB MIDI file with 12 tracks (flags: `-o:speed -disable-assert -no-bounds-check`)

AMD Ryzen 5 7530U 12-core 2.00GHz Laptop

Real-time parsing (16.67ms chunks until finished): __~1.96 msec__

Real-time parsing (single 16.67ms frame): __0.1 to 0.5 usec__ (first frame __~20 usec__)

Entire-file-at-once parsing: __~587 usec__

## License

Public Domain