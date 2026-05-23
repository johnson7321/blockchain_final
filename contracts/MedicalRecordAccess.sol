// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title MedicalRecordAccess
 * @notice 患者自主控制的電子病歷（EHR）存取管理系統，
 *         適用於相容 Hyperledger EVM 的鏈上環境。
 *         原始醫療資料存放於鏈下（IPFS / 加密儲存），
 *         鏈上僅儲存 IPFS CID 雜湊值與存取控制規則。
 *
 * 架構說明：
 *   患者  ──登記──▶ recordHash（IPFS CID）
 *   醫師  ──申請──▶ 患者授權 / 撤銷
 *   每次存取 ──記錄──▶ 不可竄改的鏈上稽核日誌
 */
contract MedicalRecordAccess {

    // ─── 資料結構 ────────────────────────────────────────────────────────

    struct Record {
        string  ipfsCID;       // 加密病歷資料的 IPFS 內容識別碼
        address owner;         // 患者錢包地址
        uint256 registeredAt;
        bool    exists;
    }

    struct AccessGrant {
        bool    granted;
        uint256 expiry;        // Unix 時間戳；0 表示永不過期
        uint256 grantedAt;
    }

    struct AccessLog {
        address accessor;
        uint256 timestamp;
        string  action;        // "READ"（讀取）| "GRANT"（授權）| "REVOKE"（撤銷）| "UPDATE"（更新）
    }

    // ─── 狀態變數 ─────────────────────────────────────────────────────────

    // 患者 ID => 病歷
    mapping(bytes32 => Record) private records;

    // 患者 ID => (醫師地址 => 授權紀錄)
    mapping(bytes32 => mapping(address => AccessGrant)) private grants;

    // 患者 ID => 存取日誌列表
    mapping(bytes32 => AccessLog[]) private accessLogs;

    // ─── 事件 ──────────────────────────────────────────────────────────────

    event RecordRegistered(bytes32 indexed patientId, address indexed owner, string ipfsCID, uint256 timestamp);
    event RecordUpdated(bytes32 indexed patientId, string newIpfsCID, uint256 timestamp);
    event AccessRequested(bytes32 indexed patientId, address indexed doctor, uint256 timestamp);
    event AccessGranted(bytes32 indexed patientId, address indexed doctor, uint256 expiry, uint256 timestamp);
    event AccessRevoked(bytes32 indexed patientId, address indexed doctor, uint256 timestamp);
    event RecordAccessed(bytes32 indexed patientId, address indexed accessor, uint256 timestamp);

    // ─── 修飾器 ───────────────────────────────────────────────────────────

    modifier onlyOwner(bytes32 patientId) {
        require(records[patientId].exists, "Record does not exist");
        require(records[patientId].owner == msg.sender, "Not the record owner");
        _;
    }

    modifier recordExists(bytes32 patientId) {
        require(records[patientId].exists, "Record does not exist");
        _;
    }

    // ─── 核心功能 ──────────────────────────────────────────────────────────

    /**
     * @notice 患者將 IPFS CID 儲存至鏈上，完成病歷登記。
     * @param patientId  唯一識別碼（例如：身份證字號的 keccak256 雜湊值）
     * @param ipfsCID    加密醫療檔案的 IPFS 內容地址
     */
    function registerRecord(bytes32 patientId, string calldata ipfsCID) external {
        require(!records[patientId].exists, "Record already registered");
        require(bytes(ipfsCID).length > 0, "Empty CID");

        records[patientId] = Record({
            ipfsCID:      ipfsCID,
            owner:        msg.sender,
            registeredAt: block.timestamp,
            exists:       true
        });

        _log(patientId, msg.sender, "REGISTER");
        emit RecordRegistered(patientId, msg.sender, ipfsCID, block.timestamp);
    }

    /**
     * @notice 患者更新 IPFS CID（例如追加新資料後）。
     * @param patientId  患者唯一識別碼
     * @param newCID     指向最新加密病歷的新 IPFS CID
     */
    function updateRecord(bytes32 patientId, string calldata newCID)
        external
        onlyOwner(patientId)
    {
        require(bytes(newCID).length > 0, "Empty CID");
        records[patientId].ipfsCID = newCID;

        _log(patientId, msg.sender, "UPDATE");
        emit RecordUpdated(patientId, newCID, block.timestamp);
    }

    /**
     * @notice 醫師申請存取權限——觸發事件；患者須於鏈下通知後呼叫 grantAccess。
     *         正式系統中應整合通知服務。
     */
    function requestAccess(bytes32 patientId) external recordExists(patientId) {
        emit AccessRequested(patientId, msg.sender, block.timestamp);
    }

    /**
     * @notice 患者授予醫師在指定期間內的病歷存取權。
     * @param patientId  患者唯一識別碼
     * @param doctor     醫師錢包地址
     * @param duration   授權時長（秒）；0 表示永久授權
     */
    function grantAccess(bytes32 patientId, address doctor, uint256 duration)
        external
        onlyOwner(patientId)
    {
        require(doctor != address(0), "Invalid doctor address");
        uint256 expiry = duration > 0 ? block.timestamp + duration : 0;

        grants[patientId][doctor] = AccessGrant({
            granted:   true,
            expiry:    expiry,
            grantedAt: block.timestamp
        });

        _log(patientId, doctor, "GRANT");
        emit AccessGranted(patientId, doctor, expiry, block.timestamp);
    }

    /**
     * @notice 患者立即撤銷醫師的存取權。
     */
    function revokeAccess(bytes32 patientId, address doctor)
        external
        onlyOwner(patientId)
    {
        require(grants[patientId][doctor].granted, "Access not granted");
        grants[patientId][doctor].granted = false;

        _log(patientId, doctor, "REVOKE");
        emit AccessRevoked(patientId, doctor, block.timestamp);
    }

    /**
     * @notice 已授權的醫師取得 IPFS CID，以便從鏈下擷取病歷。
     * @return cid  加密病歷的 IPFS 內容識別碼
     */
    function getRecord(bytes32 patientId)
        external
        recordExists(patientId)
        returns (string memory cid)
    {
        AccessGrant memory ag = grants[patientId][msg.sender];
        bool isOwner = records[patientId].owner == msg.sender;

        require(
            isOwner || (ag.granted && (ag.expiry == 0 || block.timestamp <= ag.expiry)),
            "Access denied or expired"
        );

        _log(patientId, msg.sender, "READ");
        emit RecordAccessed(patientId, msg.sender, block.timestamp);
        return records[patientId].ipfsCID;
    }

    // ─── 查詢函式 ──────────────────────────────────────────────────────────

    /**
     * @notice 確認指定地址目前是否持有對患者病歷的有效存取權。
     */
    function hasAccess(bytes32 patientId, address accessor)
        external
        view
        recordExists(patientId)
        returns (bool)
    {
        if (records[patientId].owner == accessor) return true;
        AccessGrant memory ag = grants[patientId][accessor];
        return ag.granted && (ag.expiry == 0 || block.timestamp <= ag.expiry);
    }

    /**
     * @notice 回傳病歷的元資料（不含 CID，取得 CID 須有存取授權）。
     */
    function getRecordMeta(bytes32 patientId)
        external
        view
        recordExists(patientId)
        returns (address owner, uint256 registeredAt)
    {
        Record storage r = records[patientId];
        return (r.owner, r.registeredAt);
    }

    /**
     * @notice 回傳患者病歷的完整不可竄改稽核日誌。
     *         僅限病歷擁有者（患者本人）存取。
     */
    function getAccessLog(bytes32 patientId)
        external
        view
        onlyOwner(patientId)
        returns (AccessLog[] memory)
    {
        return accessLogs[patientId];
    }

    // ─── 內部函式 ────────────────────────────────────────────────────────────

    function _log(bytes32 patientId, address actor, string memory action) internal {
        accessLogs[patientId].push(AccessLog({
            accessor:  actor,
            timestamp: block.timestamp,
            action:    action
        }));
    }
}
