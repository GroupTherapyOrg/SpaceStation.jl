import puppeteer from "puppeteer"
import { createPage } from "../helpers/common"
import { getPlutoUrl } from "../helpers/pluto"

// In the workspace a notebook is a tab's iframe, and "./" serves the Land hub itself. The editor's
// "this notebook session is no longer running" popup linked "Go back" to "./", so following it
// rendered the whole workspace (sidebar, terminals, polling) nested inside that one tab.
describe("SpaceStation notebook tabs", () => {
    /** @type {import("puppeteer").Browser} */
    let browser = null
    /** @type {import("puppeteer").Page} */
    let page = null

    beforeAll(async () => {
        browser = await puppeteer.launch({
            headless: process.env.HEADLESS !== "false" ? "new" : false,
            args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"],
        })
    })

    afterEach(async () => {
        await page?.close()
        page = null
    })

    afterAll(async () => {
        await browser?.close()
        browser = null
    })

    const tab_selector = (id) => `#frames iframe[data-tab-id="${id}"]`

    /** A running notebook, shown as a tab: the Land opens already-running notebooks as tabs on load. */
    const open_notebook_tab = async () => {
        page = await createPage(browser)
        await page.goto(getPlutoUrl(), { waitUntil: "domcontentloaded" })
        const id = await page.evaluate(async () => (await (await fetch("./new", { method: "POST" })).text()).trim())
        await page.reload({ waitUntil: "domcontentloaded" })
        const frame_handle = await page.waitForSelector(tab_selector(id), { timeout: 60000 })
        const frame = await frame_handle.contentFrame()
        await frame.waitForSelector("pluto-editor", { timeout: 60000 })
        return { id, frame }
    }

    // gone from the DOM, not merely hidden: inactive tabs are display:none, which `waitForSelector(…, { hidden: true })` accepts
    const tab_closed = (id) => page.waitForFunction((selector) => document.querySelector(selector) == null, { timeout: 20000 }, tab_selector(id))

    const nested_lands = () => page.evaluate(() => [...document.querySelectorAll("#frames iframe")].filter((f) => f.contentDocument?.getElementById("land-app")).length)

    it("closes the tab instead of nesting the workspace when the notebook session is gone", async () => {
        const { id, frame } = await open_notebook_tab()

        await page.evaluate((id) => fetch(`./shutdown?id=${id}`), id)
        await frame.waitForFunction(() => document.querySelector("pluto-popup")?.textContent.includes("no longer running"), { timeout: 60000 })

        expect(await frame.$('pluto-popup a[href="./"]')).toBeNull()
        const close = await frame.waitForSelector("xpath/.//pluto-popup//a[contains(., 'Close tab')]")
        // DOM click, not a pointer click: other running notebooks (a shared test server) also open as
        // tabs, so this tab's iframe need not be the visible one
        await close.evaluate((a) => /** @type {HTMLElement} */ (a).click())

        await tab_closed(id)
        expect(await nested_lands()).toBe(0)
    })

    it("closes a notebook tab that navigates to the hub, instead of rendering a Land inside it", async () => {
        const { id } = await open_notebook_tab()

        await page.evaluate((selector) => {
            document.querySelector(selector).contentWindow.location.href = "./"
        }, tab_selector(id))

        await tab_closed(id)
        expect(await nested_lands()).toBe(0)

        await page.evaluate((id) => fetch(`./shutdown?id=${id}`), id)
    })
})
