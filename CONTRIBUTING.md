# Contributing to Immersive-2

Thank you for your interest in contributing!

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch: `git checkout -b feature/my-feature`
4. Make your changes
5. Test your changes
6. Submit a pull request

## Development Setup

See [docs/BUILDING.md](docs/BUILDING.md) for build instructions.

## Code Style

### C++ (Host)
- C++17 standard
- Use `snake_case` for functions and variables
- Use `PascalCase` for classes and types
- Use `SCREAMING_SNAKE_CASE` for constants
- Prefix private members with `_` or use trailing `_`
- Use `#pragma once` for header guards

### GDScript (Client)
- Follow the [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html)
- Use type hints wherever possible
- Document public functions with `##` comments

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for system design details.

## Areas for Contribution

- **NVENC encoder integration** — Real NVIDIA hardware encoding
- **AMF encoder integration** — AMD hardware encoding
- **QSV encoder integration** — Intel QuickSync encoding
- **IDD driver** — Windows virtual display driver
- **MediaCodec decoder** — Android hardware video decoding (GDExtension)
- **Multi-monitor** — Multiple screen streaming
- **Virtual keyboard** — On-screen keyboard in VR
- **Performance** — Latency optimization
- **UI/UX** — Settings panel, connection UI

## Reporting Issues

- Use GitHub Issues
- Include your OS version, GPU model, and headset model
- Include logs if available

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
