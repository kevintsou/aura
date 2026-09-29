import 'model.dart';

/// Categories for a ledger started from scratch, modelled on CWMoney's.
/// Users can rename, reorder, add and delete them.
const _expense = {
  '生活費': ['早餐', '午餐', '晚餐', '飲料點心', '日用品', '其他'],
  '行車交通': ['加油', '停車費', '大眾運輸', '計程車', '保養維修', '其他'],
  '房屋支出': ['房租', '房貸', '管理費', '水費', '電費', '瓦斯', '電話網路', '其他'],
  '購物娛樂': ['購物', '服飾', '3C', '娛樂', '旅遊', '其他'],
  '醫療其他': ['醫療', '手續費', '其他'],
  '稅金保險': ['保險', '稅金', '其他'],
  '小孩花費': ['教育', '用品', '其他'],
  '大型支出': ['家電家具', '其他'],
};

const _income = {
  '工作收入': ['薪資收入', '獎金', '其他'],
  '現金流': ['投資收入', '股票股利', '利息', '其他'],
  '其他收入': ['其他'],
};

/// Parents come before their children, in display order.
List<Category> defaultCategories() => [
  for (final (kind, tree) in [
    (TxnKind.expense, _expense),
    (TxnKind.income, _income),
  ])
    for (final MapEntry(key: main, value: subs) in tree.entries) ...() {
      final parent = Category(id: newId('c'), kind: kind, name: main);
      return [
        parent,
        for (final sub in subs)
          Category(id: newId('c'), kind: kind, name: sub, parentId: parent.id),
      ];
    }(),
];

Account defaultCashAccount() => Account(
  id: newId('a'),
  name: '現金',
  type: AccountType.cash,
  currency: baseCurrency,
);
