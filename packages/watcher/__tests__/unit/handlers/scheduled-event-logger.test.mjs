// Import scheduledEventLoggerHandler function from scheduled-event-logger.mjs
import { scheduledEventLoggerHandler } from "../../../src/handlers/scheduled-event-logger.mjs";
import { encodeEventLog, parseAbiItem } from "viem";
import { jest } from "@jest/globals";

describe("Test for sqs-payload-logger", function () {
  it("Verifies the payload is logged", async () => {
    console.info = jest.fn();
    console.warn = jest.fn();
    console.log = jest.fn();

    // Create a sample payload with CloudWatch scheduled event message format
    var payload = {
      id: "cdc73f9d-aea9-11e3-9d5a-835b769c0d9c",
      "detail-type": "Scheduled Event",
      source: "aws.events",
      account: "",
      time: "1970-01-01T00:00:00Z",
      region: "us-west-2",
      resources: ["arn:aws:events:us-west-2:123456789012:rule/ExampleRule"],
      detail: {},
    };

    const sessionCreatedEvent = parseAbiItem(
      "event SessionCreated(uint64 indexed sessionId, uint64 indexed instanceId, uint64 startAt, uint32 durationSec, uint32 maxParticipants, uint256 requiredPerUser)",
    );

    const { data, topics } = encodeEventLog({
      abi: [sessionCreatedEvent],
      eventName: "SessionCreated",
      args: {
        sessionId: 1n,
        instanceId: 2n,
        startAt: 100n,
        durationSec: 3600,
        maxParticipants: 4,
        requiredPerUser: 1000n,
      },
    });

    process.env.RPC_URL = "https://example.com";
    process.env.CONTRACT_ADDRESS = "0x0000000000000000000000000000000000000001";

    global.fetch = jest.fn();
    global.fetch
      .mockResolvedValueOnce({
        json: async () => ({ result: "0xa" }),
      })
      .mockResolvedValueOnce({
        json: async () => ({
          result: [
            {
              data,
              topics,
              blockNumber: "0xa",
              transactionHash: "0xabc",
              logIndex: "0x0",
            },
          ],
        }),
      });

    await scheduledEventLoggerHandler(payload, null);

    // Verify that console.info has been called with the expected payload
    expect(console.info).toHaveBeenCalledWith(JSON.stringify(payload));
    expect(console.log).toHaveBeenCalledWith(
      JSON.stringify({
        event: "SessionCreated",
        sessionId: "1",
        instanceId: "2",
        startAt: "100",
        durationSec: "3600",
        maxParticipants: "4",
        requiredPerUser: "1000",
        blockNumber: "0xa",
        transactionHash: "0xabc",
        logIndex: "0x0",
      }),
    );
  });
});
