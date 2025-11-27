// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Ovia Escrow v1
/// @notice Minimal, event-driven escrow contract used by the Ovia protocol.
/// @dev
///  - Supports both native ETH and ERC20 tokens
///  - Funds are locked per "channel" (a job / engagement)
///  - Off-chain proof verification is done by the Ovia protocol / services,
///    this contract only enforces who can release / refund funds.
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

contract OviaEscrowV1 {
    // -----------------------
    // Types
    // -----------------------

    enum ChannelStatus {
        None,       // 0 - not used
        Funded,     // 1 - funds are locked
        Released,   // 2 - paid out to worker
        Refunded,   // 3 - refunded to client
        Canceled    // 4 - (reserved for future use)
    }

    struct Channel {
        address client;     // who funds the channel
        address worker;     // who should receive the funds
        address asset;      // address(0) = ETH, otherwise ERC20 token
        uint256 amount;     // locked amount
        uint64  deadline;   // optional: after this, client can claim refund
        ChannelStatus status;
        bytes32 metadata;   // IPFS hash / job id / off-chain reference
    }

    // -----------------------
    // Storage
    // -----------------------

    uint256 public nextChannelId = 1; // start at 1 for easier checks
    mapping(uint256 => Channel) public channels;

    /// @notice Address allowed to act as protocol (e.g. auto-release on proofs)
    address public protocol;

    /// @notice Basic owner (can update protocol address)
    address public owner;

    // Simple reentrancy guard
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // -----------------------
    // Events
    // -----------------------

    event ChannelCreated(
        uint256 indexed channelId,
        address indexed client,
        address indexed worker,
        address asset,
        uint256 amount,
        uint64 deadline,
        bytes32 metadata
    );

    event ChannelReleased(
        uint256 indexed channelId,
        address indexed client,
        address indexed worker,
        address asset,
        uint256 amount,
        address triggeredBy
    );

    event ChannelRefunded(
        uint256 indexed channelId,
        address indexed client,
        address indexed worker,
        address asset,
        uint256 amount,
        address triggeredBy
    );

    event ProtocolUpdated(address indexed oldProtocol, address indexed newProtocol);

    // -----------------------
    // Modifiers
    // -----------------------

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /// @dev msg.sender must be the channel client or the protocol (if set)
    modifier onlyClientOrProtocol(uint256 channelId) {
        Channel memory ch = channels[channelId];
        require(ch.status == ChannelStatus.Funded, "Channel not funded");
        require(
            msg.sender == ch.client || msg.sender == protocol,
            "Not authorized"
        );
        _;
    }

    // -----------------------
    // Constructor
    // -----------------------

    constructor(address _protocol) {
        owner = msg.sender;
        protocol = _protocol;
        _status = _NOT_ENTERED;
    }

    // -----------------------
    // Admin
    // -----------------------

    /// @notice Update the protocol address (can be a backend / dispatcher / dApp contract)
    function setProtocol(address _protocol) external onlyOwner {
        emit ProtocolUpdated(protocol, _protocol);
        protocol = _protocol;
    }

    // -----------------------
    // Channel creation
    // -----------------------

    /// @notice Open a new escrow channel funded with native ETH.
    /// @param worker Address that should receive the funds if released.
    /// @param deadline Unix timestamp after which client can request a refund (0 = no deadline).
    /// @param metadata Arbitrary off-chain reference (e.g. IPFS hash, job id).
    /// @return channelId Newly created channel id.
    function openChannelETH(
        address worker,
        uint64 deadline,
        bytes32 metadata
    ) external payable nonReentrant returns (uint256 channelId) {
        require(worker != address(0), "Invalid worker");
        require(msg.value > 0, "No ETH sent");

        channelId = nextChannelId++;
        channels[channelId] = Channel({
            client: msg.sender,
            worker: worker,
            asset: address(0), // ETH
            amount: msg.value,
            deadline: deadline,
            status: ChannelStatus.Funded,
            metadata: metadata
        });

        emit ChannelCreated(
            channelId,
            msg.sender,
            worker,
            address(0),
            msg.value,
            deadline,
            metadata
        );
    }

    /// @notice Open a new escrow channel funded with an ERC20 token.
    /// @dev Requires prior approval on the ERC20 for `amount` by msg.sender.
    /// @param worker Address that should receive the funds if released.
    /// @param token ERC20 token address.
    /// @param amount Amount of tokens to lock in escrow.
    /// @param deadline Unix timestamp after which client can request a refund (0 = no deadline).
    /// @param metadata Arbitrary off-chain reference (e.g. IPFS hash, job id).
    /// @return channelId Newly created channel id.
    function openChannelToken(
        address worker,
        address token,
        uint256 amount,
        uint64 deadline,
        bytes32 metadata
    ) external nonReentrant returns (uint256 channelId) {
        require(worker != address(0), "Invalid worker");
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount must be > 0");

        // Transfer tokens into escrow
        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(ok, "Token transfer failed");

        channelId = nextChannelId++;
        channels[channelId] = Channel({
            client: msg.sender,
            worker: worker,
            asset: token,
            amount: amount,
            deadline: deadline,
            status: ChannelStatus.Funded,
            metadata: metadata
        });

        emit ChannelCreated(
            channelId,
            msg.sender,
            worker,
            token,
            amount,
            deadline,
            metadata
        );
    }

    // -----------------------
    // Payout flows
    // -----------------------

    /// @notice Release funds from a channel to the worker.
    /// @dev Callable by client or protocol (if set). Assumes off-chain proof is already verified.
    /// @param channelId Id of the channel to release.
    function release(uint256 channelId)
        external
        nonReentrant
        onlyClientOrProtocol(channelId)
    {
        Channel storage ch = channels[channelId];
        require(ch.status == ChannelStatus.Funded, "Not funded");

        ch.status = ChannelStatus.Released;
        uint256 amount = ch.amount;
        address asset = ch.asset;
        address worker = ch.worker;
        address client = ch.client;

        ch.amount = 0; // defensive

        if (asset == address(0)) {
            // ETH
            (bool sent, ) = worker.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            // ERC20
            bool ok = IERC20(asset).transfer(worker, amount);
            require(ok, "Token transfer failed");
        }

        emit ChannelReleased(
            channelId,
            client,
            worker,
            asset,
            amount,
            msg.sender
        );
    }

    /// @notice Refund funds from a channel back to the client.
    /// @dev
    ///  - Only callable by client or protocol.
    ///  - If deadline > 0, current timestamp must be >= deadline.
    /// @param channelId Id of the channel to refund.
    function refund(uint256 channelId)
        external
        nonReentrant
        onlyClientOrProtocol(channelId)
    {
        Channel storage ch = channels[channelId];
        require(ch.status == ChannelStatus.Funded, "Not funded");

        if (ch.deadline != 0) {
            require(block.timestamp >= ch.deadline, "Too early to refund");
        }

        ch.status = ChannelStatus.Refunded;
        uint256 amount = ch.amount;
        address asset = ch.asset;
        address worker = ch.worker;
        address client = ch.client;

        ch.amount = 0; // defensive

        if (asset == address(0)) {
            (bool sent, ) = client.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            bool ok = IERC20(asset).transfer(client, amount);
            require(ok, "Token transfer failed");
        }

        emit ChannelRefunded(
            channelId,
            client,
            worker,
            asset,
            amount,
            msg.sender
        );
    }

    // -----------------------
    // View helpers
    // -----------------------

    /// @notice Return full channel data in one call.
    function getChannel(uint256 channelId)
        external
        view
        returns (Channel memory)
    {
        return channels[channelId];
    }

    /// @notice Convenience helper: is this channel still active (funded)?
    function isActive(uint256 channelId) external view returns (bool) {
        return channels[channelId].status == ChannelStatus.Funded;
    }
}

