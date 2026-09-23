## Installing VLS for other editors

### Table of contents

- [Kate](#kate)

### Kate

1. Build VLS with `v .` and place the resulting `vls` binary in your `PATH`.
2. Open `Settings > Configure Kate... > LSP Client > User Server Settings`.
3. Add this to your settings file:

```json
{
    "servers": {
        "v": {
            "command": ["vls"],
            "highlightingModeRegex": "^V$"
        }
    }
}
```

or alternatively if the `vls` binary is NOT in your `PATH`:

```json
{
    "servers": {
        "v": {
            "command": ["/absolute/path/to/vls"],
            "highlightingModeRegex": "^V$"
        }
    }
}
```

4. When you first open a V source file, a popup will appear asking whether you want to start the LSP. Click `Yes`, and VLS will be started and added to the allowed servers list.

#### Post-Installation

To configure VLS go to `LSP Client > More Options > ...`

If you wish to temporarily disable the LSP you have two options:

- Turn on `LSP Client > Suspend All`, which will suspend all LSPs, including VLS, but also other servers too.

- In `Settings > Configure Kate... > LSP Client > Allowed & Blocked Servers`, disable the entry named as the abosolute path to the VLS binary.
