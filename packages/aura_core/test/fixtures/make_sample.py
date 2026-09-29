#!/usr/bin/env python3
"""Builds sample_cwmoney.csv: a synthetic CWMoney classic export.

All data is made up. It reproduces the quirks found in real exports
(see docs/cwmoney-format.md): Big5-HKSCS, CRLF records, LF inside notes,
an unescaped quote, transfer flags 0/1/2, FX subtotals, negative amounts.
"""
HKSCS_CHAR = bytes([0x9D, 0xE8]).decode("big5hkscs")  # not in CP950

H = ["日期", "類別", "主分類", "子分類", "帳戶", "專案", "金額", "匯率", "小計",
     "建檔時間", "GPS", "地址", "發票號碼", "轉帳", "備註"]
N = "無特別專案"
rows = [
    # invoice with multi-line items, discount, unescaped quote, HKSCS char
    ["2026/09/28", "支出", "生活費", "早餐", "信用卡-測試", N, "65", "1", "65",
     "2026/09/29 10:10:29", "0.0 : 0.0", "(測試便利商店股份有限公司,臺北市測試路１號)",
     "AB12345678", "0",
     '茶葉蛋x2=20\n13"鮮奶' + HKSCS_CHAR + 'x1=55\n點數折抵x1=-10\n(12345678,測試便利商店股份有限公司)\n[手機條碼,/TEST123]'],
    # fuel with fractional quantity
    ["2026/09/27", "支出", "行車交通", "加油", "信用卡-測試", N, "1800", "1", "1800",
     "2026/09/27 18:31:35", "0.0 : 0.0", "(測試加油站,新竹市測試路２號)", "CD87654321", "0",
     "95無鉛汽油x56.68=1853\n(87654321,測試加油站)\n[手機條碼,/TEST123]"],
    # plain income with project
    ["2026/09/25", "收入", "工作收入", "薪資收入", "活存-測試", "測試專案", "50000", "1", "50000",
     "2026/09/25 09:10:22", "", " ", "", "0", "九月薪水"],
    # exact transfer pair (income row first)
    ["2026/09/24", "收入", "", "", "現金", N, "3000", "1", "3000",
     "2026/09/24 13:44:34", "", " ", "", "1", "[帳戶轉帳]"],
    ["2026/09/24", "支出", "", "", "活存-測試", N, "3000", "1", "3000",
     "2026/09/24 13:44:34", "", " ", "", "1", "[帳戶轉帳]"],
    # transfer fee linked to the pair above
    ["2026/09/24", "支出", "醫療其他", "手續費", "活存-測試", N, "15", "1", "15",
     "2026/09/24 13:44:34", "", " ", "", "2", "[手續費][帳戶轉帳]"],
    # fuzzy pair: creation times one second apart, custom note
    ["2026/09/23", "收入", "", "", "定存-測試", N, "100000", "1", "100000",
     "2026/09/23 09:52:11", "", " ", "", "1", "轉定存"],
    ["2026/09/23", "支出", "", "", "活存-測試", N, "100000", "1", "100000",
     "2026/09/23 09:52:10", "", " ", "", "1", "轉定存"],
    # cross-currency transfer: amounts differ, subtotal equal
    ["2026/09/22", "收入", "", "", "活存-測試", N, "32370", "1", "32370",
     "2026/09/22 08:56:19", "", " ", "", "1", "[帳戶轉帳]"],
    ["2026/09/22", "支出", "", "", "美金-測試", N, "1000", "32.37", "32370",
     "2026/09/22 08:56:19", "", " ", "", "1", "[帳戶轉帳]"],
    # one-sided transfer
    ["2026/09/21", "支出", "", "", "活存-測試", N, "5000", "1", "5000",
     "2026/09/21 11:00:00", "", " ", "", "1", "[帳戶轉帳]"],
    # foreign expense: subtotal is not amount x rate
    ["2026/09/20", "支出", "購物娛樂", "購物", "日幣-測試", N, "10000", "0.2", "2010",
     "2026/09/20 21:18:12", "0:0", " ", "", "0", "東京買東西"],
    # negative income (investment loss) and empty creation time
    ["2026/09/19", "收入", "現金流", "投資收入", "股票-測試", N, "-1874.5", "1", "-1874.5",
     "", "", " ", "", "0", "賣出虧損"],
    # manual expense with a typed place
    ["2026/09/18", "支出", "生活費", "午餐", "現金", N, "120", "1", "120",
     "2026/09/18 12:30:00", "", "公司樓下", "", "0", "便當"],
]
out = "\r\n".join('"' + '","'.join(r) + '"' for r in [H] + rows) + "\r\n"
open("sample_cwmoney.csv", "wb").write(out.encode("big5hkscs"))
print("hkscs char", repr(HKSCS_CHAR))
