import test from "node:test";
import assert from "node:assert/strict";
import { evaluatePersistedCall } from "../src/lib/performance-milestones.ts";

const call = (previousPeak = 1, published = 0) => ({
  tokenAddress: "stored-address", entryPriceUsd: 1,
  callMarketCapUsd: 50_000, peakMultiple: previousPeak,
  lastPublicMilestone: published,
});
const at = (multiple) => new Map([["stored-address", {
  priceUsd: multiple, marketCapUsd: 50_000 * multiple,
}]]);

test("A: 2.90X is below the first public result", () => {
  assert.equal(evaluatePersistedCall(call(), at(2.9)).nextMilestone, 0);
});
test("B: 3.05X publishes 3X", () => {
  assert.equal(evaluatePersistedCall(call(), at(3.05)).nextMilestone, 3);
});
test("C: 4.90X after 3X has no new result", () => {
  assert.equal(evaluatePersistedCall(call(3.05, 3), at(4.9)).nextMilestone, 0);
});
test("D: 5.10X after 3X publishes 5X", () => {
  assert.equal(evaluatePersistedCall(call(3.05, 3), at(5.1)).nextMilestone, 5);
});
test("E: jump from 2.50X to 11X publishes only 10X", () => {
  assert.equal(evaluatePersistedCall(call(2.5), at(11)).nextMilestone, 10);
});
test("F and G: persisted address is tracked with an empty scanner result", () => {
  const scannerSignals = [];
  assert.equal(scannerSignals.length, 0);
  assert.equal(evaluatePersistedCall(call(3, 3), at(5.1)).nextMilestone, 5);
});
test("H: current falls while historical peak remains", () => {
  const result = evaluatePersistedCall(call(3.6, 3), at(1.2));
  assert.equal(result.current, 1.2);
  assert.equal(result.peak, 3.6);
});
test("I: persisted published milestone prevents redeploy duplicate", () => {
  assert.equal(evaluatePersistedCall(call(5.1, 5), at(5.1)).nextMilestone, 0);
});
test("J: failed market fetch produces no overwrite", () => {
  assert.equal(evaluatePersistedCall(call(3.6, 3), new Map()), null);
});
test("K: old call age is absent from eligibility", () => {
  const oldCall = { ...call(2.5, 0), calledAt: Date.now() - 90 * 86_400_000 };
  assert.equal(evaluatePersistedCall(oldCall, at(10.2)).nextMilestone, 10);
});
