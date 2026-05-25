# 區塊鏈醫療健康管理系統 PoC

基於以太坊相容鏈（EVM）的醫療健康資料管理概念驗證（Proof of Concept）專案，涵蓋兩個核心智能合約與互動式前端介面。

---

## 專案簡介

本專案探討區塊鏈技術如何解決醫療領域的兩大核心問題：

1. **病歷隱私與存取控制**：患者自主掌握電子病歷（EHR）的授權與撤銷，原始資料存於鏈下（IPFS），鏈上僅保存 CID 雜湊與存取規則。
2. **藥品供應鏈溯源**：從製造商到患者的端到端追蹤，整合冷鏈溫度記錄、召回通報與 QR Code 驗真。

---

## 專案結構

```
blockchain_final/
├── contracts/
│   ├── MedicalRecordAccess.sol   # 病歷存取控制合約
│   └── DrugTraceability.sol      # 藥品溯源合約
├── index.html                    # 互動式前端 PoC（ethers.js）
├── 區塊鏈醫療健康資料管理研究報告_v5.docx
├── 區塊鏈醫療健康研究_投影片_v9.pdf
├── 區塊鏈醫療健康研究_投影片_v9.pptx
└── 封存/                         # 歷版本報告與投影片
```

---

## 智能合約

### MedicalRecordAccess.sol

患者自主控制的電子病歷存取管理系統。

| 函式 | 說明 |
|------|------|
| `registerRecord` | 患者將 IPFS CID 登記至鏈上 |
| `updateRecord` | 患者更新 IPFS CID |
| `grantAccess` | 授予醫師存取權（可設定到期時間） |
| `revokeAccess` | 立即撤銷醫師存取權 |
| `getRecord` | 已授權的醫師取得 IPFS CID |
| `getAccessLog` | 患者查詢不可竄改的存取稽核日誌 |

### DrugTraceability.sol

藥品供應鏈端到端溯源系統，支援角色型存取控制（RBAC）。

**角色**：`ADMIN` / `MANUFACTURER` / `DISTRIBUTOR` / `PHARMACY` / `REGULATOR`

| 函式 | 說明 |
|------|------|
| `mintDrug` | 製造商建立批次紀錄 |
| `transferDrug` | 批次持有權轉移 |
| `updateTemperature` | 記錄冷鏈溫度（× 100，避免浮點數） |
| `verifyDrug` | 驗證藥品真偽（任何人皆可呼叫） |
| `dispenseDrug` | 藥局標記已發藥 |
| `recallDrug` | 主管機關發布召回 |

> 內建 `simulationMode`，允許單一 ADMIN 錢包模擬完整供應鏈流程，方便 Remix IDE 驗證。

---

## 快速開始

### 使用 Remix IDE 部署合約

1. 開啟 [Remix IDE](https://remix.ethereum.org/)
2. 將 `contracts/` 下的 `.sol` 檔案貼入編輯器
3. 選擇 Solidity 編譯器版本 `^0.8.0`
4. 部署至 `Remix VM`（本機測試）或 MetaMask 連接的測試網
5. 複製合約地址，填入 `index.html` 中對應的欄位

### 使用前端介面

1. 以瀏覽器直接開啟 `index.html`
2. 連接 MetaMask 錢包（需切換至正確網路）
3. 透過角色選擇器切換身份，操作對應功能面板

---

## 技術架構

| 層次 | 技術 |
|------|------|
| 智能合約 | Solidity `^0.8.0`、EVM 相容鏈 |
| 鏈下儲存 | IPFS（加密病歷資料） |
| 前端 | 純 HTML/CSS/JS + ethers.js 5.7 |
| 開發工具 | Remix IDE |

---

## 研究背景

- 醫療業資料外洩平均成本達 **$7.42M USD**，連續 14 年居各行業之首（IBM, 2025）
- Change Healthcare 事件波及 **1.9 億筆**病歷，為美國史上最大規模醫療資料外洩
- WHO 估計低中收入國家每 10 種藥品中有 **1 種為假冒**

區塊鏈透過去中心化、不可竄改與智能合約自動化，提供傳統中心化系統難以達成的透明度與信任基礎。

---

## 授權

本專案為學術研究用途，僅供概念驗證展示。
