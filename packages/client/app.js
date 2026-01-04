import {
  createPublicClient,
  createWalletClient,
  custom,
  decodeEventLog,
  isAddress,
  parseAbi,
} from "https://esm.sh/viem";
import { avalancheFuji } from "https://esm.sh/viem/chains";

const formCreate = document.getElementById("create-session-form");
const formApprove = document.getElementById("approve-form");
const formDeposit = document.getElementById("deposit-form");
const statusText = document.getElementById("statusText");
const chainPill = document.getElementById("chainPill");
const logOutput = document.getElementById("logOutput");

const instanceIdInput = document.getElementById("instanceId");
const maxParticipantsInput = document.getElementById("maxParticipants");
const startAtInput = document.getElementById("startAt");
const durationInput = document.getElementById("durationSec");
const approveAmountInput = document.getElementById("approveAmount");
const depositSessionIdInput = document.getElementById("depositSessionId");
const depositAmountInput = document.getElementById("depositAmount");

const CONTRACT_ADDRESS = "0xa5A54985B061B9Ea2Ef3a29A3B0e7781E9d100cF";
const USDC_ADDRESS = "0x5425890298aed601595a70AB815c96711a31Bc65";

const sessionAbi = parseAbi([
  "function createSession(uint64 instanceId, uint32 maxParticipants, uint64 startAt, uint32 durationSec) external returns (uint64)",
  "function deposit(uint64 sessionId, uint256 amount) external",
  "event SessionCreated(uint64 indexed sessionId, uint64 indexed instanceId, uint64 startAt, uint32 durationSec, uint32 maxParticipants, uint256 requiredPerUser)",
]);

const usdcAbi = parseAbi([
  "function approve(address spender, uint256 amount) external returns (bool)",
]);

const setStatus = (message) => {
  statusText.textContent = message;
};

const setLog = (message) => {
  logOutput.textContent = message;
};

const toBigInt = (value, label) => {
  const trimmed = value.trim();
  if (!trimmed) {
    throw new Error(`${label} is required.`);
  }
  try {
    if (/^0x[0-9a-fA-F]+$/.test(trimmed)) {
      return BigInt(trimmed);
    }
    if (!/^[0-9]+$/.test(trimmed)) {
      throw new Error(`${label} must be a number string.`);
    }
    return BigInt(trimmed);
  } catch {
    throw new Error(`${label} is not a valid integer.`);
  }
};

const updateChainPill = async () => {
  if (!window.ethereum) {
    chainPill.textContent = "Chain: -";
    return;
  }
  try {
    const chainIdHex = await window.ethereum.request({ method: "eth_chainId" });
    chainPill.textContent = `Chain: ${parseInt(chainIdHex, 16)}`;
  } catch {
    chainPill.textContent = "Chain: unknown";
  }
};

const connectWallet = async ({ requestOnLoad = false } = {}) => {
  if (!window.ethereum) {
    setStatus("No wallet detected.");
    setLog("Install a wallet like MetaMask to continue.");
    return null;
  }

  try {
    const method = requestOnLoad ? "eth_requestAccounts" : "eth_accounts";
    const existing = await window.ethereum.request({ method });
    if (existing.length > 0) {
      setStatus(`Connected: ${existing[0]}`);
      return existing[0];
    }

    if (!requestOnLoad) {
      setStatus("Requesting wallet connection...");

      const walletClient = createWalletClient({
        transport: custom(window.ethereum),
      });
      const [account] = await walletClient.requestAddresses();
      setStatus(`Connected: ${account}`);
      return account;
    }

    setStatus("Wallet connection not granted.");
    return null;
  } catch (error) {
    setStatus("Wallet connection failed.");
    setLog(error?.shortMessage || error?.message || "Connection rejected.");
    return null;
  }
};

const getWalletClient = () => {
  return createWalletClient({
    chain: avalancheFuji,
    transport: custom(window.ethereum),
  });
};

const getPublicClient = () => {
  return createPublicClient({
    chain: avalancheFuji,
    transport: custom(window.ethereum),
  });
};

const ensureContractAddress = () => {
  if (!CONTRACT_ADDRESS || !isAddress(CONTRACT_ADDRESS)) {
    setStatus("Contract address is missing.");
    setLog("Set CONTRACT_ADDRESS in app.js before submitting.");
    return false;
  }
  return true;
};

const ensureUsdcAddress = () => {
  if (!USDC_ADDRESS || !isAddress(USDC_ADDRESS)) {
    setStatus("USDC address is missing.");
    setLog("Set USDC_ADDRESS in app.js before submitting.");
    return false;
  }
  return true;
};

const handleError = (error) => {
  setStatus("Transaction failed.");
  setLog(error?.shortMessage || error?.message || "Unknown error.");
};

const explainRevert = async (hash, receipt) => {
  try {
    const publicClient = getPublicClient();
    const tx = await publicClient.getTransaction({ hash });
    await publicClient.call({
      to: tx.to,
      data: tx.input,
      account: tx.from,
      value: tx.value,
      blockNumber: receipt.blockNumber,
    });
  } catch (error) {
    return error?.shortMessage || error?.message || null;
  }
  return null;
};

const findSessionCreated = (receipt) => {
  for (const log of receipt.logs || []) {
    try {
      const decoded = decodeEventLog({
        abi: sessionAbi,
        data: log.data,
        topics: log.topics,
      });
      if (decoded.eventName === "SessionCreated") {
        return decoded.args.sessionId;
      }
    } catch {
      continue;
    }
  }
  return null;
};

const init = async () => {
  await connectWallet({ requestOnLoad: true });
  await updateChainPill();

  if (window.ethereum?.on) {
    window.ethereum.on("chainChanged", updateChainPill);
    window.ethereum.on("accountsChanged", (accounts) => {
      if (accounts.length > 0) {
        setStatus(`Connected: ${accounts[0]}`);
      } else {
        setStatus("Wallet disconnected.");
      }
    });
  }
};

init();

formCreate.addEventListener("submit", async (event) => {
  event.preventDefault();

  if (!ensureContractAddress()) {
    return;
  }

  let args;
  try {
    args = [
      toBigInt(instanceIdInput.value, "Instance ID"),
      toBigInt(maxParticipantsInput.value, "Max Participants"),
      toBigInt(startAtInput.value, "Start At"),
      toBigInt(durationInput.value, "Duration"),
    ];
  } catch (error) {
    setStatus("Invalid input.");
    setLog(error.message);
    return;
  }

  const submitButton = formCreate.querySelector("button");
  submitButton.disabled = true;
  setStatus("Checking wallet...");

  try {
    const account = await connectWallet();
    if (!account) {
      return;
    }

    setStatus("Submitting createSession...");

    const hash = await getWalletClient().writeContract({
      address: CONTRACT_ADDRESS,
      abi: sessionAbi,
      functionName: "createSession",
      args,
      account,
    });

    setStatus("Waiting for confirmation...");

    const receipt = await getPublicClient().waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      const reason = await explainRevert(hash, receipt);
      setStatus("Transaction reverted.");
      setLog(reason ? `Revert reason: ${reason}` : `Tx reverted: ${hash}`);
      return;
    }
    const sessionId = findSessionCreated(receipt);

    if (sessionId !== null) {
      setStatus(`Session created: ${sessionId}`);
    } else {
      setStatus("Session created.");
    }
    setLog(`Tx hash: ${hash}`);
  } catch (error) {
    handleError(error);
  } finally {
    submitButton.disabled = false;
    updateChainPill();
  }
});

formApprove.addEventListener("submit", async (event) => {
  event.preventDefault();

  if (!ensureContractAddress() || !ensureUsdcAddress()) {
    return;
  }

  let amount;
  try {
    amount = toBigInt(approveAmountInput.value, "Approve Amount");
  } catch (error) {
    setStatus("Invalid input.");
    setLog(error.message);
    return;
  }

  const submitButton = formApprove.querySelector("button");
  submitButton.disabled = true;
  setStatus("Checking wallet...");

  try {
    const account = await connectWallet();
    if (!account) {
      return;
    }

    setStatus("Submitting approve...");

    const hash = await getWalletClient().writeContract({
      address: USDC_ADDRESS,
      abi: usdcAbi,
      functionName: "approve",
      args: [CONTRACT_ADDRESS, amount],
      account,
    });

    setStatus("Waiting for confirmation...");

    const receipt = await getPublicClient().waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      const reason = await explainRevert(hash, receipt);
      setStatus("Transaction reverted.");
      setLog(reason ? `Revert reason: ${reason}` : `Tx reverted: ${hash}`);
      return;
    }

    setStatus("Approve confirmed.");
    setLog(`Tx hash: ${hash}`);
  } catch (error) {
    handleError(error);
  } finally {
    submitButton.disabled = false;
    updateChainPill();
  }
});

formDeposit.addEventListener("submit", async (event) => {
  event.preventDefault();

  if (!ensureContractAddress()) {
    return;
  }

  let args;
  try {
    args = [
      toBigInt(depositSessionIdInput.value, "Session ID"),
      toBigInt(depositAmountInput.value, "Amount"),
    ];
  } catch (error) {
    setStatus("Invalid input.");
    setLog(error.message);
    return;
  }

  const submitButton = formDeposit.querySelector("button");
  submitButton.disabled = true;
  setStatus("Checking wallet...");

  try {
    const account = await connectWallet();
    if (!account) {
      return;
    }

    setStatus("Submitting deposit...");

    const hash = await getWalletClient().writeContract({
      address: CONTRACT_ADDRESS,
      abi: sessionAbi,
      functionName: "deposit",
      args,
      account,
    });

    setStatus("Waiting for confirmation...");

    const receipt = await getPublicClient().waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      const reason = await explainRevert(hash, receipt);
      setStatus("Transaction reverted.");
      setLog(reason ? `Revert reason: ${reason}` : `Tx reverted: ${hash}`);
      return;
    }

    setStatus("Deposit confirmed.");
    setLog(`Tx hash: ${hash}`);
  } catch (error) {
    handleError(error);
  } finally {
    submitButton.disabled = false;
    updateChainPill();
  }
});
