// Julia installation knowledge for the desktop shell: which juliaup channels exist, which one
// the user prefers, and where settings live. juliaup state is read from its own metadata file
// (~/.julia/juliaup/juliaup.json) — structured and stable, no CLI output parsing.

export const home_dir = () => Deno.env.get("HOME") ?? Deno.env.get("USERPROFILE") ?? "."

export const data_dir = () =>
    Deno.build.os === "darwin"
        ? `${home_dir()}/Library/Application Support/SpaceStation`
        : Deno.build.os === "windows"
          ? `${Deno.env.get("APPDATA") ?? home_dir()}/SpaceStation`
          : `${Deno.env.get("XDG_DATA_HOME") ?? `${home_dir()}/.local/share`}/spacestation`

export type JuliaSettings = { channel: string | null; ask: boolean }

const settings_path = () => `${data_dir()}/settings.json`

export const load_settings = (): { julia?: JuliaSettings } => {
    try {
        return JSON.parse(Deno.readTextFileSync(settings_path()))
    } catch {
        return {}
    }
}

export const save_settings = (patch: Record<string, unknown>) => {
    try {
        Deno.mkdirSync(data_dir(), { recursive: true })
        Deno.writeTextFileSync(settings_path(), JSON.stringify({ ...load_settings(), ...patch }, null, 2))
    } catch (e) {
        console.warn("could not save settings:", e)
    }
}

export const juliaup_bin = (): string | null => {
    const exe = Deno.build.os === "windows" ? "juliaup.exe" : "juliaup"
    for (const candidate of [`${home_dir()}/.juliaup/bin/${exe}`, exe]) {
        try {
            if (candidate.includes("/") || candidate.includes("\\")) Deno.statSync(candidate)
            return candidate
        } catch {
            // not at the well-known path; bare name is tried via PATH at spawn time
        }
    }
    return null
}

export type JuliaupInfo = { default: string | null; channels: Array<{ name: string; version: string }> }

/** Installed channels + default, from juliaup's own metadata. Null when juliaup isn't set up. */
export const juliaup_info = (): JuliaupInfo | null => {
    try {
        const depot = Deno.env.get("JULIAUP_DEPOT_PATH") ?? Deno.env.get("JULIA_DEPOT_PATH")?.split(":")[0] ?? `${home_dir()}/.julia`
        const meta = JSON.parse(Deno.readTextFileSync(`${depot}/juliaup/juliaup.json`))
        const channels = Object.entries(meta.InstalledChannels ?? {})
            .map(([name, v]: [string, any]) => ({ name, version: String(v?.Version ?? "").split("+")[0] }))
            .sort((a, b) => (a.name === meta.Default ? -1 : b.name === meta.Default ? 1 : a.name.localeCompare(b.name, undefined, { numeric: true })))
        return { default: meta.Default ?? null, channels }
    } catch {
        return null
    }
}

/** Channels worth offering as one-click installs on the picker. */
export const CURATED_CHANNELS = ["release", "lts", "1.12", "1.11", "1.10"]

/** Is a bare `julia` runnable (no juliaup)? Used for the picker's system-julia row. */
export const has_plain_julia = async (): Promise<string | null> => {
    for (const candidate of [Deno.env.get("SPACESTATION_JULIA"), "julia", "/opt/homebrew/bin/julia", "/usr/local/bin/julia"].filter((c): c is string => !!c)) {
        try {
            const out = await new Deno.Command(candidate, { args: ["--version"], stdout: "piped", stderr: "null" }).output()
            if (out.success) return new TextDecoder().decode(out.stdout).trim()
        } catch {
            // keep looking
        }
    }
    return null
}
