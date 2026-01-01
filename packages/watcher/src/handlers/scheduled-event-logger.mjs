/**
 * A Lambda function that logs the payload received from a CloudWatch scheduled event.
 */
import {
  EC2Client,
  StartInstancesCommand,
  StopInstancesCommand,
} from "@aws-sdk/client-ec2";
import { decodeEventLog, hexToBigInt, numberToHex, parseAbiItem } from "viem";

const sessionCreatedEvent = parseAbiItem(
  "event SessionCreated(uint64 indexed sessionId, uint64 indexed instanceId, uint64 startAt, uint32 durationSec, uint32 maxParticipants, uint256 requiredPerUser)",
);

const rpcRequest = async (rpcUrl, method, params) => {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params,
    }),
  });

  const payload = await response.json();
  if (payload.error) {
    throw new Error(payload.error.message || "RPC error");
  }
  return payload.result;
};

const parseInstanceIds = (value) => {
  if (!value) return [];
  return value
    .split(",")
    .map((id) => id.trim())
    .filter(Boolean);
};

const handleEc2Action = async () => {
  const action = (process.env.EC2_ACTION || "").toLowerCase();
  const instanceIds = parseInstanceIds(process.env.EC2_INSTANCE_IDS);
  if (!action || instanceIds.length === 0) {
    console.info("EC2 action not configured; skipping.");
    return;
  }

  const client = new EC2Client({
    region: process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION,
  });

  if (action === "start") {
    await client.send(new StartInstancesCommand({ InstanceIds: instanceIds }));
    console.log(JSON.stringify({ action: "start", instanceIds: instanceIds }));
    return;
  }

  if (action === "stop") {
    await client.send(new StopInstancesCommand({ InstanceIds: instanceIds }));
    console.log(JSON.stringify({ action: "stop", instanceIds: instanceIds }));
    return;
  }

  console.warn(`Unknown EC2_ACTION: ${action}`);
};

export const scheduledEventLoggerHandler = async (event, context) => {
  // All log statements are written to CloudWatch by default. For more information, see
  // https://docs.aws.amazon.com/lambda/latest/dg/nodejs-prog-model-logging.html
  console.info(JSON.stringify(event));

  const rpcUrl = process.env.RPC_URL;
  const contractAddress = process.env.CONTRACT_ADDRESS;
  if (!rpcUrl || !contractAddress) {
    console.warn("RPC_URL or CONTRACT_ADDRESS is not set; skipping log fetch.");
    await handleEc2Action();
    return;
  }

  const latestBlockHex = await rpcRequest(rpcUrl, "eth_blockNumber", []);
  const latestBlock = hexToBigInt(latestBlockHex);
  const fromBlock = latestBlock > 20n ? latestBlock - 20n : 0n;

  const logs = await rpcRequest(rpcUrl, "eth_getLogs", [
    {
      address: contractAddress,
      fromBlock: numberToHex(fromBlock),
      toBlock: "latest",
      topics: [sessionCreatedEvent.hash],
    },
  ]);

  for (const log of logs) {
    try {
      const decoded = decodeEventLog({
        abi: [sessionCreatedEvent],
        data: log.data,
        topics: log.topics,
      });
      const args = decoded.args;

      const structured = {
        event: "SessionCreated",
        sessionId: args.sessionId.toString(),
        instanceId: args.instanceId.toString(),
        startAt: args.startAt.toString(),
        durationSec: args.durationSec.toString(),
        maxParticipants: args.maxParticipants.toString(),
        requiredPerUser: args.requiredPerUser.toString(),
        blockNumber: log.blockNumber,
        transactionHash: log.transactionHash,
        logIndex: log.logIndex,
      };

      console.log(JSON.stringify(structured));
    } catch (error) {
      console.warn("Failed to decode SessionCreated log", error);
    }
  }

  await handleEc2Action();
};
