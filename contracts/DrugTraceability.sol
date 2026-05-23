// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title DrugTraceability
 * @notice 藥品供應鏈端到端溯源系統。
 *         每批藥品於鏈上鑄造為唯一紀錄，
 *         每次持有人轉移、冷鏈溫度更新
 *         及零售驗真均永久記錄於鏈上。
 *
 * 角色說明：
 *   MANUFACTURER  — 製造商，建立（鑄造）批次紀錄
 *   DISTRIBUTOR   — 配送商，接收並轉移批次
 *   PHARMACY      — 藥局，驗證並發藥給患者
 *   REGULATOR     — 主管機關，可隨時發布召回
 *   ADMIN         — 管理員，負責角色指派
 */
contract DrugTraceability {

    // ─── 角色系統 ─────────────────────────────────────────────────────────

    enum Role { NONE, ADMIN, MANUFACTURER, DISTRIBUTOR, PHARMACY, REGULATOR }

    mapping(address => Role) public roles;

    /**
     * @notice 模擬模式開關（PoC 專用）。
     *         開啟時 ADMIN 可呼叫所有角色限定的函式，
     *         方便單一錢包模擬整條供應鏈流程。
     */
    bool public simulationMode = true;

    modifier onlyRole(Role r) {
        require(
            roles[msg.sender] == r ||
            (simulationMode && roles[msg.sender] == Role.ADMIN),
            "Insufficient role"
        );
        _;
    }

    modifier onlyRoles(Role r1, Role r2) {
        require(
            roles[msg.sender] == r1 ||
            roles[msg.sender] == r2 ||
            (simulationMode && roles[msg.sender] == Role.ADMIN),
            "Insufficient role"
        );
        _;
    }

    modifier onlyAdmin() {
        require(roles[msg.sender] == Role.ADMIN, "Admin only");
        _;
    }

    /// @notice 管理員可切換模擬模式（預設開啟）。
    function setSimulationMode(bool enabled) external onlyAdmin {
        simulationMode = enabled;
    }

    // ─── 資料結構 ─────────────────────────────────────────────────────────

    enum BatchStatus { MANUFACTURED, IN_TRANSIT, AT_PHARMACY, DISPENSED, RECALLED }

    struct Batch {
        bytes32     batchId;
        string      drugName;
        string      manufacturer;
        uint256     manufactureDate;
        uint256     expiryDate;
        BatchStatus status;
        address     currentHolder;
        bool        exists;
    }

    struct TransferRecord {
        address   from;
        address   to;
        uint256   timestamp;
        string    location;    // 例如：「台北倉庫」、「桃園藥局 #3」
    }

    struct TemperatureLog {
        int256  celsius;       // 乘以 100 避免浮點數（例如 235 = 2.35°C）
        uint256 timestamp;
        address reporter;      // IoT 閘道器錢包地址
    }

    // ─── 狀態變數 ─────────────────────────────────────────────────────────

    mapping(bytes32 => Batch)            private batches;
    mapping(bytes32 => TransferRecord[]) private transferHistory;
    mapping(bytes32 => TemperatureLog[]) private temperatureLogs;
    mapping(bytes32 => bool)             public  recalls;

    bytes32[] public allBatchIds;   // 可枚舉索引

    // ─── 事件 ──────────────────────────────────────────────────────────────

    event BatchMinted(bytes32 indexed batchId, string drugName, address manufacturer, uint256 timestamp);
    event BatchTransferred(bytes32 indexed batchId, address indexed from, address indexed to, string location, uint256 timestamp);
    event TemperatureRecorded(bytes32 indexed batchId, int256 celsius, address reporter, uint256 timestamp);
    event BatchVerified(bytes32 indexed batchId, address verifier, bool authentic, uint256 timestamp);
    event BatchRecalled(bytes32 indexed batchId, address regulator, string reason, uint256 timestamp);
    event BatchDispensed(bytes32 indexed batchId, address pharmacy, uint256 timestamp);
    event RoleAssigned(address indexed account, Role role, uint256 timestamp);

    // ─── 建構子 ─────────────────────────────────────────────────────────

    constructor() {
        roles[msg.sender] = Role.ADMIN;
        emit RoleAssigned(msg.sender, Role.ADMIN, block.timestamp);
    }

    // ─── 角色管理 ─────────────────────────────────────────────────────────

    /**
     * @notice 管理員指派角色給指定地址。
     */
    function assignRole(address account, Role role) external onlyAdmin {
        require(account != address(0), "Zero address");
        roles[account] = role;
        emit RoleAssigned(account, role, block.timestamp);
    }

    // ─── 核心供應鏈功能 ─────────────────────────────────────────────────────

    /**
     * @notice 製造商在鏈上鑄造一筆新的藥品批次紀錄。
     * @param drugName   藥品名稱（人類可讀）
     * @param batchCode  來自製造商系統的唯一批次代碼
     * @param expiryDate 到期日之 Unix 時間戳
     */
    function mintDrug(
        string calldata drugName,
        string calldata batchCode,
        uint256         expiryDate
    ) external onlyRole(Role.MANUFACTURER) returns (bytes32 batchId) {
        require(bytes(drugName).length > 0, "Empty drug name");
        require(expiryDate > block.timestamp, "Expiry must be in the future");

        batchId = keccak256(abi.encodePacked(batchCode, msg.sender, block.timestamp));
        require(!batches[batchId].exists, "Batch ID collision");

        batches[batchId] = Batch({
            batchId:         batchId,
            drugName:        drugName,
            manufacturer:    _addrToString(msg.sender),
            manufactureDate: block.timestamp,
            expiryDate:      expiryDate,
            status:          BatchStatus.MANUFACTURED,
            currentHolder:   msg.sender,
            exists:          true
        });

        allBatchIds.push(batchId);

        // 初始轉移紀錄：製造商 → 自身（溯源錨點）
        transferHistory[batchId].push(TransferRecord({
            from:      address(0),
            to:        msg.sender,
            timestamp: block.timestamp,
            location:  "Manufacturing Facility"
        }));

        emit BatchMinted(batchId, drugName, msg.sender, block.timestamp);
        return batchId;
    }

    /**
     * @notice 將批次持有權轉移給另一方（配送商或藥局）。
     * @param batchId   由 mintDrug 回傳的批次識別碼
     * @param to        接收方地址（須持有 DISTRIBUTOR 或 PHARMACY 角色）
     * @param location  人類可讀的地點描述
     */
    function transferDrug(bytes32 batchId, address to, string calldata location)
        external
        onlyRoles(Role.MANUFACTURER, Role.DISTRIBUTOR)
    {
        _requireBatch(batchId);
        require(!recalls[batchId], "Batch has been recalled");
        require(
            batches[batchId].currentHolder == msg.sender ||
            (simulationMode && roles[msg.sender] == Role.ADMIN),
            "Not current holder"
        );
        require(
            roles[to] == Role.DISTRIBUTOR || roles[to] == Role.PHARMACY,
            "Recipient must be DISTRIBUTOR or PHARMACY"
        );

        batches[batchId].currentHolder = to;
        batches[batchId].status = (roles[to] == Role.PHARMACY)
            ? BatchStatus.AT_PHARMACY
            : BatchStatus.IN_TRANSIT;

        transferHistory[batchId].push(TransferRecord({
            from:      msg.sender,
            to:        to,
            timestamp: block.timestamp,
            location:  location
        }));

        emit BatchTransferred(batchId, msg.sender, to, location, block.timestamp);
    }

    /**
     * @notice IoT 閘道器記錄一筆冷鏈溫度讀數。
     * @param batchId  批次識別碼
     * @param celsius  溫度 × 100（例如 235 = 2.35°C，-50 = -0.50°C）
     */
    function updateTemperature(bytes32 batchId, int256 celsius)
        external
        onlyRoles(Role.DISTRIBUTOR, Role.MANUFACTURER)
    {
        _requireBatch(batchId);
        temperatureLogs[batchId].push(TemperatureLog({
            celsius:   celsius,
            timestamp: block.timestamp,
            reporter:  msg.sender
        }));
        emit TemperatureRecorded(batchId, celsius, msg.sender, block.timestamp);
    }

    /**
     * @notice 藥局或患者掃描 QR Code 驗證藥品真偽。
     * @return authentic 若批次存在、未被召回且未過期則回傳 true
     */
    function verifyDrug(bytes32 batchId)
        external
        returns (bool authentic)
    {
        if (!batches[batchId].exists) {
            emit BatchVerified(batchId, msg.sender, false, block.timestamp);
            return false;
        }
        authentic = !recalls[batchId] && block.timestamp <= batches[batchId].expiryDate;
        emit BatchVerified(batchId, msg.sender, authentic, block.timestamp);
        return authentic;
    }

    /**
     * @notice 藥局將批次標記為已發藥給患者。
     */
    function dispenseDrug(bytes32 batchId) external onlyRole(Role.PHARMACY) {
        _requireBatch(batchId);
        require(!recalls[batchId], "Batch recalled");
        require(
            batches[batchId].currentHolder == msg.sender ||
            (simulationMode && roles[msg.sender] == Role.ADMIN),
            "Not current holder"
        );
        require(batches[batchId].status == BatchStatus.AT_PHARMACY, "Not at pharmacy");

        batches[batchId].status = BatchStatus.DISPENSED;
        emit BatchDispensed(batchId, msg.sender, block.timestamp);
    }

    /**
     * @notice 主管機關發布批次召回，立即廣播至所有節點。
     * @param reason 人類可讀的召回原因（例如「污染」、「劑量錯誤」）
     */
    function recallDrug(bytes32 batchId, string calldata reason)
        external
        onlyRole(Role.REGULATOR)
    {
        _requireBatch(batchId);
        recalls[batchId] = true;
        batches[batchId].status = BatchStatus.RECALLED;
        emit BatchRecalled(batchId, msg.sender, reason, block.timestamp);
    }

    // ─── 查詢函式 ───────────────────────────────────────────────────────────

    /**
     * @notice 回傳批次的完整元資料。
     */
    function getBatch(bytes32 batchId)
        external
        view
        returns (
            string memory drugName,
            string memory manufacturer,
            uint256 manufactureDate,
            uint256 expiryDate,
            BatchStatus status,
            address currentHolder,
            bool recalled
        )
    {
        _requireBatch(batchId);
        // 避免建立 storage 指標以防止 EVM「stack too deep」錯誤
        return (
            batches[batchId].drugName,
            batches[batchId].manufacturer,
            batches[batchId].manufactureDate,
            batches[batchId].expiryDate,
            batches[batchId].status,
            batches[batchId].currentHolder,
            recalls[batchId]
        );
    }

    /**
     * @notice 回傳批次的完整溯源鏈（轉移歷程）。
     */
    function getTransferHistory(bytes32 batchId)
        external
        view
        returns (TransferRecord[] memory)
    {
        _requireBatch(batchId);
        return transferHistory[batchId];
    }

    /**
     * @notice 回傳批次的所有溫度記錄。
     */
    function getTemperatureLogs(bytes32 batchId)
        external
        view
        returns (TemperatureLog[] memory)
    {
        _requireBatch(batchId);
        return temperatureLogs[batchId];
    }

    /**
     * @notice 回傳已登記的批次總數。
     */
    function totalBatches() external view returns (uint256) {
        return allBatchIds.length;
    }

    // ─── 內部輔助函式 ────────────────────────────────────────────────────────

    function _requireBatch(bytes32 batchId) internal view {
        require(batches[batchId].exists, "Batch does not exist");
    }

    function _addrToString(address addr) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(addr)));
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2]     = alphabet[uint8(value[i + 12] >> 4)];
            str[3 + i * 2]     = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }
}
