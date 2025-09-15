(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_SUBSCRIPTION (err u101))
(define-constant ERR_SUBSCRIPTION_EXPIRED (err u102))
(define-constant ERR_INSUFFICIENT_PAYMENT (err u103))
(define-constant ERR_FEATURE_NOT_FOUND (err u104))
(define-constant ERR_ALREADY_SUBSCRIBED (err u105))
(define-constant ERR_INVALID_TIER (err u106))
(define-constant ERR_CANNOT_TRANSFER_TO_SELF (err u107))
(define-constant ERR_RECIPIENT_HAS_SUBSCRIPTION (err u108))
(define-constant ERR_TRANSFER_NOT_ALLOWED (err u109))

(define-data-var next-subscription-id uint u1)
(define-data-var platform-fee-percentage uint u5)
(define-data-var total-revenue uint u0)

(define-map subscriptions
  { subscription-id: uint }
  {
    user: principal,
    tier: uint,
    start-block: uint,
    duration-blocks: uint,
    is-active: bool,
    amount-paid: uint,
    creator: principal
  }
)

(define-map user-subscriptions
  { user: principal }
  { active-subscription-id: uint }
)

(define-map subscription-tiers
  { tier-id: uint }
  {
    name: (string-ascii 50),
    price-per-block: uint,
    max-features: uint,
    creator-revenue-share: uint
  }
)

(define-map features
  { feature-id: uint }
  {
    name: (string-ascii 100),
    required-tier: uint,
    creator: principal,
    is-active: bool
  }
)

(define-map user-feature-access
  { user: principal, feature-id: uint }
  { has-access: bool, granted-block: uint }
)

(define-map creator-balances
  { creator: principal }
  { balance: uint }
)

(define-map subscription-transfers
  { transfer-id: uint }
  {
    subscription-id: uint,
    from-user: principal,
    to-user: principal,
    transfer-block: uint,
    is-gift: bool
  }
)

(define-data-var next-transfer-id uint u1)
(define-map paused-subscriptions
  { subscription-id: uint }
  { paused-at: uint, is-paused: bool }
)

(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-percentage)) u100)
)

(define-private (calculate-creator-share (amount uint) (revenue-share uint))
  (/ (* amount revenue-share) u100)
)

(define-read-only (get-subscription (subscription-id uint))
  (map-get? subscriptions { subscription-id: subscription-id })
)

(define-read-only (get-user-subscription (user principal))
  (map-get? user-subscriptions { user: user })
)

(define-read-only (get-subscription-tier (tier-id uint))
  (map-get? subscription-tiers { tier-id: tier-id })
)

(define-read-only (get-feature (feature-id uint))
  (map-get? features { feature-id: feature-id })
)

(define-read-only (check-feature-access (user principal) (feature-id uint))
  (default-to { has-access: false, granted-block: u0 }
    (map-get? user-feature-access { user: user, feature-id: feature-id }))
)

(define-read-only (is-subscription-active (subscription-id uint))
  (match (get-subscription subscription-id)
    subscription
      (let (
        (start-block (get start-block subscription))
        (duration (get duration-blocks subscription))
        (is-active (get is-active subscription))
      )
      (and is-active (< burn-block-height (+ start-block duration))))
    false)
)

(define-read-only (get-creator-balance (creator principal))
  (default-to { balance: u0 }
    (map-get? creator-balances { creator: creator }))
)

(define-read-only (get-subscription-transfer (transfer-id uint))
  (map-get? subscription-transfers { transfer-id: transfer-id })
)

(define-read-only (can-transfer-subscription (user principal))
  (match (get-user-subscription user)
    user-sub
      (let (
        (sub-id (get active-subscription-id user-sub))
      )
      (match (get-subscription sub-id)
        subscription
          (let (
            (start-block (get start-block subscription))
            (duration (get duration-blocks subscription))
            (blocks-remaining (- (+ start-block duration) burn-block-height))
          )
          (and 
            (get is-active subscription)
            (> blocks-remaining u144)))
        false))
    false)
)

(define-public (create-subscription-tier 
  (tier-id uint) 
  (name (string-ascii 50)) 
  (price-per-block uint) 
  (max-features uint) 
  (creator-revenue-share uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (asserts! (<= creator-revenue-share u95) ERR_INVALID_TIER)
    (map-set subscription-tiers
      { tier-id: tier-id }
      {
        name: name,
        price-per-block: price-per-block,
        max-features: max-features,
        creator-revenue-share: creator-revenue-share
      })
    (ok tier-id))
)

(define-public (create-feature 
  (feature-id uint) 
  (name (string-ascii 100)) 
  (required-tier uint))
  (begin
    (map-set features
      { feature-id: feature-id }
      {
        name: name,
        required-tier: required-tier,
        creator: tx-sender,
        is-active: true
      })
    (ok feature-id))
)

(define-public (subscribe (tier-id uint) (duration-blocks uint))
  (let (
    (subscription-id (var-get next-subscription-id))
    (existing-sub (get-user-subscription tx-sender))
  )
  (match (get-subscription-tier tier-id)
    tier-info
      (let (
        (total-cost (* (get price-per-block tier-info) duration-blocks))
        (platform-fee (calculate-platform-fee total-cost))
        (creator-share (calculate-creator-share total-cost (get creator-revenue-share tier-info)))
      )
      (begin
        (asserts! (is-none existing-sub) ERR_ALREADY_SUBSCRIBED)
        (try! (stx-transfer? total-cost tx-sender (as-contract tx-sender)))
        
        (map-set subscriptions
          { subscription-id: subscription-id }
          {
            user: tx-sender,
            tier: tier-id,
            start-block: burn-block-height,
            duration-blocks: duration-blocks,
            is-active: true,
            amount-paid: total-cost,
            creator: CONTRACT_OWNER
          })
        
        (map-set user-subscriptions
          { user: tx-sender }
          { active-subscription-id: subscription-id })
        
        (var-set next-subscription-id (+ subscription-id u1))
        (var-set total-revenue (+ (var-get total-revenue) total-cost))
        
        (ok subscription-id)))
    ERR_INVALID_TIER))
)

(define-public (renew-subscription (additional-blocks uint))
  (match (get-user-subscription tx-sender)
    user-sub
      (let (
        (sub-id (get active-subscription-id user-sub))
      )
      (match (get-subscription sub-id)
        subscription
          (match (get-subscription-tier (get tier subscription))
            tier-info
              (let (
                (renewal-cost (* (get price-per-block tier-info) additional-blocks))
              )
              (begin
                (try! (stx-transfer? renewal-cost tx-sender (as-contract tx-sender)))
                (map-set subscriptions
                  { subscription-id: sub-id }
                  (merge subscription { 
                    duration-blocks: (+ (get duration-blocks subscription) additional-blocks),
                    amount-paid: (+ (get amount-paid subscription) renewal-cost)
                  }))
                (var-set total-revenue (+ (var-get total-revenue) renewal-cost))
                (ok sub-id)))
            ERR_INVALID_TIER)
        ERR_INVALID_SUBSCRIPTION))
    ERR_INVALID_SUBSCRIPTION)
)

(define-public (cancel-subscription)
  (match (get-user-subscription tx-sender)
    user-sub
      (let (
        (sub-id (get active-subscription-id user-sub))
      )
      (match (get-subscription sub-id)
        subscription
          (begin
            (map-set subscriptions
              { subscription-id: sub-id }
              (merge subscription { is-active: false }))
            (map-delete user-subscriptions { user: tx-sender })
            (ok sub-id))
        ERR_INVALID_SUBSCRIPTION))
    ERR_INVALID_SUBSCRIPTION)
)

(define-public (grant-feature-access (user principal) (feature-id uint))
  (match (get-user-subscription user)
    user-sub
      (let (
        (sub-id (get active-subscription-id user-sub))
      )
      (match (get-subscription sub-id)
        subscription
          (match (get-feature feature-id)
            feature
              (let (
                (user-tier (get tier subscription))
                (required-tier (get required-tier feature))
              )
              (begin
                (asserts! (>= user-tier required-tier) ERR_UNAUTHORIZED)
                (asserts! (is-subscription-active sub-id) ERR_SUBSCRIPTION_EXPIRED)
                (map-set user-feature-access
                  { user: user, feature-id: feature-id }
                  { has-access: true, granted-block: burn-block-height })
                (ok true)))
            ERR_FEATURE_NOT_FOUND)
        ERR_INVALID_SUBSCRIPTION))
    ERR_INVALID_SUBSCRIPTION)
)

(define-public (revoke-feature-access (user principal) (feature-id uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (map-set user-feature-access
      { user: user, feature-id: feature-id }
      { has-access: false, granted-block: burn-block-height })
    (ok true))
)

(define-public (withdraw-creator-balance)
  (let (
    (balance-info (get-creator-balance tx-sender))
    (amount (get balance balance-info))
  )
  (begin
    (asserts! (> amount u0) ERR_INSUFFICIENT_PAYMENT)
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    (map-set creator-balances
      { creator: tx-sender }
      { balance: u0 })
    (ok amount)))
)

(define-public (set-platform-fee (new-fee uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (asserts! (<= new-fee u20) ERR_INVALID_TIER)
    (var-set platform-fee-percentage new-fee)
    (ok new-fee))
)

(define-public (transfer-subscription (recipient principal))
  (let (
    (transfer-id (var-get next-transfer-id))
  )
  (match (get-user-subscription tx-sender)
    sender-sub
      (let (
        (sub-id (get active-subscription-id sender-sub))
      )
      (match (get-subscription sub-id)
        subscription
          (let (
            (recipient-existing-sub (get-user-subscription recipient))
          )
          (begin
            (asserts! (not (is-eq tx-sender recipient)) ERR_CANNOT_TRANSFER_TO_SELF)
            (asserts! (is-none recipient-existing-sub) ERR_RECIPIENT_HAS_SUBSCRIPTION)
            (asserts! (can-transfer-subscription tx-sender) ERR_TRANSFER_NOT_ALLOWED)
            (asserts! (is-subscription-active sub-id) ERR_SUBSCRIPTION_EXPIRED)
            
            (map-set subscriptions
              { subscription-id: sub-id }
              (merge subscription { user: recipient }))
            
            (map-delete user-subscriptions { user: tx-sender })
            (map-set user-subscriptions
              { user: recipient }
              { active-subscription-id: sub-id })
            
            (map-set subscription-transfers
              { transfer-id: transfer-id }
              {
                subscription-id: sub-id,
                from-user: tx-sender,
                to-user: recipient,
                transfer-block: burn-block-height,
                is-gift: false
              })
            
            (var-set next-transfer-id (+ transfer-id u1))
            (ok transfer-id)))
        ERR_INVALID_SUBSCRIPTION))
    ERR_INVALID_SUBSCRIPTION))
)

(define-public (gift-subscription (recipient principal) (tier-id uint) (duration-blocks uint))
  (let (
    (subscription-id (var-get next-subscription-id))
    (transfer-id (var-get next-transfer-id))
    (recipient-existing-sub (get-user-subscription recipient))
  )
  (match (get-subscription-tier tier-id)
    tier-info
      (let (
        (total-cost (* (get price-per-block tier-info) duration-blocks))
        (platform-fee (calculate-platform-fee total-cost))
        (creator-share (calculate-creator-share total-cost (get creator-revenue-share tier-info)))
      )
      (begin
        (asserts! (not (is-eq tx-sender recipient)) ERR_CANNOT_TRANSFER_TO_SELF)
        (asserts! (is-none recipient-existing-sub) ERR_RECIPIENT_HAS_SUBSCRIPTION)
        (try! (stx-transfer? total-cost tx-sender (as-contract tx-sender)))
        
        (map-set subscriptions
          { subscription-id: subscription-id }
          {
            user: recipient,
            tier: tier-id,
            start-block: burn-block-height,
            duration-blocks: duration-blocks,
            is-active: true,
            amount-paid: total-cost,
            creator: CONTRACT_OWNER
          })
        
        (map-set user-subscriptions
          { user: recipient }
          { active-subscription-id: subscription-id })
        
        (map-set subscription-transfers
          { transfer-id: transfer-id }
          {
            subscription-id: subscription-id,
            from-user: tx-sender,
            to-user: recipient,
            transfer-block: burn-block-height,
            is-gift: true
          })
        
        (var-set next-subscription-id (+ subscription-id u1))
        (var-set next-transfer-id (+ transfer-id u1))
        (var-set total-revenue (+ (var-get total-revenue) total-cost))

        (ok subscription-id)))
    ERR_INVALID_TIER))
)

(define-public (pause-subscription)
  (match (get-user-subscription tx-sender)
    user-sub
      (let (
        (sub-id (get active-subscription-id user-sub))
      )
      (match (get-subscription sub-id)
        subscription
          (let (
            (is-paused (default-to false (get is-paused (map-get? paused-subscriptions { subscription-id: sub-id }))))
          )
          (begin
            (asserts! (is-subscription-active sub-id) ERR_SUBSCRIPTION_EXPIRED)
            (asserts! (not is-paused) ERR_INVALID_SUBSCRIPTION)
            (map-set paused-subscriptions
              { subscription-id: sub-id }
              { paused-at: burn-block-height, is-paused: true })
            (ok sub-id)))
        ERR_INVALID_SUBSCRIPTION))
    ERR_INVALID_SUBSCRIPTION)
)

(define-public (resume-subscription)
  (match (get-user-subscription tx-sender)
    user-sub
      (let (
        (sub-id (get active-subscription-id user-sub))
      )
      (match (get-subscription sub-id)
        subscription
          (let (
            (paused-info (map-get? paused-subscriptions { subscription-id: sub-id }))
          )
          (match paused-info
            p-info
              (let (
                (paused-at (get paused-at p-info))
                (is-paused (get is-paused p-info))
                (paused-duration (- burn-block-height paused-at))
              )
              (begin
                (asserts! is-paused ERR_INVALID_SUBSCRIPTION)
                (map-set subscriptions
                  { subscription-id: sub-id }
                  (merge subscription { duration-blocks: (+ (get duration-blocks subscription) paused-duration) }))
                (map-set paused-subscriptions
                  { subscription-id: sub-id }
                  { paused-at: u0, is-paused: false })
                (ok sub-id)))
            ERR_INVALID_SUBSCRIPTION))
        ERR_INVALID_SUBSCRIPTION))
    ERR_INVALID_SUBSCRIPTION)
)

(create-subscription-tier u1 "Basic" u10 u5 u70)
(create-subscription-tier u2 "Pro" u25 u15 u75)
(create-subscription-tier u3 "Enterprise" u50 u50 u80)
