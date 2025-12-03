# FLAC Downsampler

A command line tool to downsample FLAC files.

- Written in Zig 0.15.1
- Uses no libraries aside from [libFLAC](https://github.com/xiph/flac) statically linked and built with the [Zig Build System](https://ziglang.org/learn/build-system/)
- Uses a custom FIR low-pass filtering and decimation by an integer factor

I have some 192kHz music that I wanted to put on my iPod, which only supports up to 48kHz.
I also didn't want to use FFmpeg, because thats boring, so I took it as a chance to learn a new library and a bit of DSP.

## Usage

Super basic right now, but it'll change at some point:

```
$ flac_downsampler.exe
Usage: flac_downsampler.exe [SAMPLE_RATE] [INPUT_FILE] [OUTPUT_FILE]


$ flac_downsampler.exe 48000 "Equus Caballus - 08 Where I Sit.flac" "[48kHz] Equus Caballus - 08 Where I Sit.flac"
```
