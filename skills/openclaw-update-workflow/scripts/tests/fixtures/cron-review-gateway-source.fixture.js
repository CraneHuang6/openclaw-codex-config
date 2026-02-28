function resolveHeartbeatAckMaxChars(agentCfg) {
  return agentCfg?.heartbeat?.ackMaxChars ?? 200;
}

export async function runCronJob(params) {
  const runSessionId = "session-123";
  const workspaceDir = "/tmp/workspace";
  const runStartedAt = Date.now();
  let runEndedAt = runStartedAt;

  const runResult = params.runResult ?? {};
  const firstText = "";
  const payloads = runResult.payloads ?? [];
  const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
  const outputText = pickLastNonEmptyTextFromPayloads(payloads);
  const synthesizedText = outputText?.trim() || summary?.trim() || void 0;

  const deliveryPayload = params.deliveryPayload;
  const deliveryPayloadHasStructuredContent = Boolean(deliveryPayload?.mediaUrl);
  if (deliveryPayloadHasStructuredContent) {
    return withRunSession({
      status: "ok",
      summary,
      outputText: synthesizedText,
    });
  }

  runEndedAt = Date.now();
  return withRunSession({
    status: "ok",
    summary,
    outputText: synthesizedText,
  });
}
