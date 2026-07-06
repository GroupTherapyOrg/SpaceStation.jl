# Pluto end-to-end tests

All commands here are executed in this folder (`Pluto.jl/test/frontend`).

## Install packages

`npm install`

## Run Pluto.jl server

These tests exercise classic autorun Pluto — SpaceStation's lazy default would leave opened notebooks un-run (`on_code_change="autorun"` below is required; the lazy/collab behavior is tested by `test/collab_*.sh` instead).

```
PLUTO_PORT=2345; julia --project=/path/to/PlutoDev -e "import SpaceStation; SpaceStation.run(port=$PLUTO_PORT, require_secret_for_access=false, launch_browser=false, on_code_change=\"autorun\")"
```

or if SpaceStation is dev'ed in your global environment:

```
PLUTO_PORT=2345; julia -e "import SpaceStation; SpaceStation.run(port=$PLUTO_PORT, require_secret_for_access=false, launch_browser=false, on_code_change=\"autorun\")"
```

## Run tests

`PLUTO_PORT=2345 npm run test`

## View the browser in action

Add `HEADLESS=false` when running the test command.

`clear && HEADLESS=false PLUTO_PORT=1234 npm run test`

## Run a particular suite of tests

Add `-- -t=name of the suite` to the end of the test command.

`clear && HEADLESS=false PLUTO_PORT=1234 npm run test -- -t=PlutoAutocomplete`

## To make a test fail on a case that does not crash Pluto

Use `console.error("PlutoError ...")`. This suite will fail if a console
command has PlutoError in the text. Do that when a bad situation is handled
but the underlying cause exists.
