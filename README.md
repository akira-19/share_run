# Share Run

## Directories

- packages/client: Demo UI
- packages/foundry: Smart Contract
- packages/watcher: Event Listner(aws SAM project)

## Usage

### Demo UI

```shell
npx serve .
```

### Smart Contract

#### デプロイ
```shell
forge script script/DeploySharedServerRuntime.s.sol --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast
```

### Event Listner

#### デプロイ
```shell
sam build
sam deploy
```
