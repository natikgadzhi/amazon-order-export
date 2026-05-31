import Foundation

/// One line item within an order.
///
/// Fields are optional because the two sources expose different detail: the
/// orders-*list* page gives title + asin + quantity (and sometimes only an image
/// for grocery grids), while the order-*details* page adds `unitPrice` and `soldBy`.
public struct OrderItem: Equatable, Sendable {
    public var asin: String?
    public var title: String?
    public var quantity: Int
    public var imageURL: String?
    public var unitPrice: Money?
    public var soldBy: String?

    public init(
        asin: String? = nil, title: String? = nil, quantity: Int = 1,
        imageURL: String? = nil, unitPrice: Money? = nil, soldBy: String? = nil
    ) {
        self.asin = asin
        self.title = title
        self.quantity = quantity
        self.imageURL = imageURL
        self.unitPrice = unitPrice
        self.soldBy = soldBy
    }
}

/// One order as seen on the orders-list page (the cheap bulk source).
public struct OrderSummary: Equatable, Sendable {
    public var id: String
    public var orderPlaced: Date?
    public var orderPlacedRaw: String
    public var total: Money?
    public var recipient: String?
    public var detailPath: String?
    public var items: [OrderItem]
    /// "and N more" badge on grocery grids — items beyond the few shown.
    public var andMoreCount: Int

    public init(
        id: String, orderPlaced: Date?, orderPlacedRaw: String, total: Money?,
        recipient: String?, detailPath: String?, items: [OrderItem], andMoreCount: Int
    ) {
        self.id = id
        self.orderPlaced = orderPlaced
        self.orderPlacedRaw = orderPlacedRaw
        self.total = total
        self.recipient = recipient
        self.detailPath = detailPath
        self.items = items
        self.andMoreCount = andMoreCount
    }
}

/// The whole orders-list page: the orders plus the bits we need to walk it.
public struct OrdersPage: Equatable, Sendable {
    public var orderCount: Int?
    public var selectedYear: String?
    public var orders: [OrderSummary]
    /// `startIndex` values from the pager, so a caller can fetch every page.
    public var pageStartIndices: [Int]

    public init(
        orderCount: Int?, selectedYear: String?, orders: [OrderSummary],
        pageStartIndices: [Int]
    ) {
        self.orderCount = orderCount
        self.selectedYear = selectedYear
        self.orders = orders
        self.pageStartIndices = pageStartIndices
    }
}

/// One row of the order-details charge summary, e.g. ("Grand Total", $29.83).
public struct ChargeLine: Equatable, Sendable {
    public var label: String
    public var amount: Money
    public init(label: String, amount: Money) {
        self.label = label
        self.amount = amount
    }
}

/// The card an order was charged to. `lastFour` is the bank-statement join key.
public struct PaymentInstrument: Equatable, Sendable {
    public var description: String
    public var lastFour: String?
    public init(description: String, lastFour: String?) {
        self.description = description
        self.lastFour = lastFour
    }
}

/// One order as seen on its order-details page — the transactions-spine record:
/// order id + grand total + card last-4 + the `/cpe/yourpayments/transactions`
/// tag, which together let us reconcile against a bank statement line.
public struct OrderDetail: Equatable, Sendable {
    public var id: String?
    public var orderPlaced: Date?
    public var orderPlacedRaw: String?
    public var grandTotal: Money?
    public var charges: [ChargeLine]
    public var payment: PaymentInstrument?
    public var transactionsTag: String?
    public var items: [OrderItem]

    public init(
        id: String?, orderPlaced: Date?, orderPlacedRaw: String?, grandTotal: Money?,
        charges: [ChargeLine], payment: PaymentInstrument?, transactionsTag: String?,
        items: [OrderItem]
    ) {
        self.id = id
        self.orderPlaced = orderPlaced
        self.orderPlacedRaw = orderPlacedRaw
        self.grandTotal = grandTotal
        self.charges = charges
        self.payment = payment
        self.transactionsTag = transactionsTag
        self.items = items
    }
}
