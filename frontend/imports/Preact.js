// @ts-nocheck
// Preact, its hooks and htm are copies in ./vendor (the versions named there), not fetched from a
// CDN: every page of the app starts with this file, and a page that cannot start until another
// site answers is one that sometimes takes half a minute, and never starts on a machine without
// internet (a cluster's compute node).
import { render, Component, h, cloneElement, createContext, createRef, hydrate } from "./vendor/preact.js"
import {
    //
    useEffect,
    useLayoutEffect,
    useState,
    useRef,
    useMemo,
    useCallback,
    useContext,
    useErrorBoundary,
} from "./vendor/preact-hooks.js"

import htm from "./vendor/htm.js"

const html = htm.bind(h)

export {
    //
    html,
    render,
    Component,
    useEffect,
    useLayoutEffect,
    useState,
    useRef,
    useMemo,
    useCallback,
    useErrorBoundary,
    createContext,
    createRef,
    useContext,
    h,
    cloneElement,
    hydrate,
}
