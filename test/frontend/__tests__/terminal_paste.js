import fs from "fs"
import os from "os"
import path from "path"
import puppeteer from "puppeteer"
import { createPage } from "../helpers/common"
import { getPlutoUrl } from "../helpers/pluto"

describe("SpaceStation terminal", () => {
    /** @type {import("puppeteer").Browser} */
    let browser = null
    /** @type {import("puppeteer").Page} */
    let page = null
    let sentinel = null

    beforeAll(async () => {
        browser = await puppeteer.launch({
            headless: process.env.HEADLESS !== "false" ? "new" : false,
            args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"],
        })
    })

    afterEach(async () => {
        await page?.close()
        page = null
        if (sentinel != null) fs.rmSync(sentinel, { force: true })
    })

    afterAll(async () => {
        await browser?.close()
        browser = null
    })

    it("uses native text paste once without requesting clipboard-read permission", async () => {
        sentinel = path.join(os.tmpdir(), `spacestation-terminal-paste-${process.pid}-${Date.now()}`)
        const command = `printf X >> '${sentinel}'`
        page = await createPage(browser)

        // The old handler explicitly read the clipboard on Cmd+V while xterm also handled the
        // browser's native paste event. Mocking the Clipboard API and delivering both events makes
        // the competing keydown + native-paste paths deterministic: old code writes XX and invokes
        // the permission-gated Clipboard API, while fixed code writes X without reading the clipboard.
        await page.evaluateOnNewDocument((text) => {
            window.__clipboardReadCalls = 0
            Object.defineProperty(navigator, "clipboard", {
                configurable: true,
                value: {
                    read: async () => {
                        window.__clipboardReadCalls += 1
                        throw new Error("force the legacy readText fallback")
                    },
                    readText: async () => {
                        window.__clipboardReadCalls += 1
                        return text
                    },
                    writeText: async () => {},
                },
            })
        }, command)

        await page.goto(getPlutoUrl(), { waitUntil: "domcontentloaded" })
        await page.waitForSelector("button.terminal-toggle", { visible: true })
        await page.click("button.terminal-toggle")
        await page.waitForSelector(".terminal-host .xterm-helper-textarea", { visible: true, timeout: 30000 })

        await page.evaluate((text) => {
            const textarea = document.querySelector(".terminal-host .xterm-helper-textarea")
            textarea.focus()
            textarea.dispatchEvent(new KeyboardEvent("keydown", { key: "v", metaKey: true, bubbles: true, cancelable: true }))
            const clipboardData = new DataTransfer()
            clipboardData.setData("text/plain", text)
            textarea.dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true, composed: true }))
        }, command)

        // Let the legacy async Clipboard API path finish before submitting the shell command.
        await new Promise((resolve) => setTimeout(resolve, 100))
        await page.keyboard.press("Enter")

        const deadline = Date.now() + 10000
        let result = ""
        while (Date.now() < deadline) {
            try {
                result = fs.readFileSync(sentinel, "utf8")
            } catch {}
            if (result !== "") break
            await new Promise((resolve) => setTimeout(resolve, 50))
        }
        expect(result).toBe("X")
        expect(await page.evaluate(() => window.__clipboardReadCalls)).toBe(0)
    })

    it("restores an open terminal on hard refresh without creating another", async () => {
        page = await createPage(browser)
        await page.goto(getPlutoUrl(), { waitUntil: "domcontentloaded" })
        await page.evaluate(() => {
            localStorage.removeItem("spacestation terminals by workspace")
            localStorage.removeItem("spacestation terminals")
            localStorage.removeItem("spacestation terminal open")
        })
        await page.reload({ waitUntil: "domcontentloaded" })

        await page.waitForSelector("button.terminal-toggle", { visible: true })
        await page.click("button.terminal-toggle")
        await page.waitForSelector(".terminal-host .xterm-helper-textarea", { visible: true, timeout: 30000 })
        await page.waitForFunction(() => document.querySelectorAll(".terminal-tab .title").length === 1)
        await page.waitForFunction(() => {
            const saved = Object.values(JSON.parse(localStorage.getItem("spacestation terminals by workspace") ?? "{}"))
            return saved.flat().length === 1
        })

        const original_tid = await page.evaluate(() => {
            const saved = Object.values(JSON.parse(localStorage.getItem("spacestation terminals by workspace") ?? "{}"))
            return saved.flat()[0]?.tid ?? null
        })
        expect(original_tid).not.toBeNull()

        await page.reload({ waitUntil: "domcontentloaded" })
        await page.waitForSelector(".terminal-host .xterm-helper-textarea", { visible: true, timeout: 30000 })
        // Let all post-load effects settle; the old race appended Terminal 2 here.
        await new Promise((resolve) => setTimeout(resolve, 500))

        expect(await page.$$eval(".terminal-tab .title", (tabs) => tabs.map((tab) => tab.getAttribute("title")))).toEqual(["Terminal 1"])
        const restored_tids = await page.evaluate(() => {
            const saved = Object.values(JSON.parse(localStorage.getItem("spacestation terminals by workspace") ?? "{}"))
            return saved.flat().map((terminal) => terminal.tid)
        })
        expect(restored_tids).toEqual([original_tid])
    })
})
