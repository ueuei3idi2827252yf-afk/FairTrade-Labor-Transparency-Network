;; Worker Rights Registry Smart Contract
;; Tracks fair wage practices and working conditions from factory to finished product
;; Provides immutable records of worker rights compliance and violations

;; ===== CONSTANTS =====
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-invalid-input (err u103))
(define-constant err-unauthorized (err u104))
(define-constant err-insufficient-wage (err u105))
(define-constant err-unsafe-conditions (err u106))

;; Minimum acceptable wage per hour (in micro-STX)
(define-constant minimum-wage-per-hour u1000000)

;; Working condition safety thresholds
(define-constant max-working-hours-per-day u12)
(define-constant min-safety-score u75)

;; ===== DATA STRUCTURES =====

;; Worker registry data
(define-map workers
    { worker-id: uint }
    {
        worker-address: principal,
        factory-id: uint,
        employment-date: uint,
        is-active: bool,
        total-wage-paid: uint,
        hours-worked: uint,
        safety-violations: uint
    }
)

;; Factory registry data
(define-map factories
    { factory-id: uint }
    {
        factory-owner: principal,
        factory-name: (string-ascii 64),
        location: (string-ascii 128),
        certification-level: uint,
        total-workers: uint,
        compliance-score: uint,
        last-inspection: uint,
        is-certified: bool
    }
)

;; Wage payment records
(define-map wage-payments
    { payment-id: uint }
    {
        worker-id: uint,
        factory-id: uint,
        amount: uint,
        hours-worked: uint,
        payment-date: uint,
        is-fair-wage: bool,
        hourly-rate: uint
    }
)

;; Working condition assessments
(define-map working-conditions
    { assessment-id: uint }
    {
        factory-id: uint,
        inspector-address: principal,
        safety-score: uint,
        working-hours-per-day: uint,
        has-safety-equipment: bool,
        ventilation-adequate: bool,
        emergency-protocols: bool,
        assessment-date: uint,
        overall-compliance: bool
    }
)

;; Product traceability records
(define-map products
    { product-id: uint }
    {
        factory-id: uint,
        product-name: (string-ascii 64),
        production-date: uint,
        worker-ids: (list 20 uint),
        total-labor-cost: uint,
        fair-trade-certified: bool,
        quality-score: uint
    }
)

;; Authorization registry for inspectors and auditors
(define-map authorized-inspectors
    { inspector-address: principal }
    { is-authorized: bool, authorization-date: uint }
)

;; ===== DATA VARIABLES =====
(define-data-var next-worker-id uint u1)
(define-data-var next-factory-id uint u1)
(define-data-var next-payment-id uint u1)
(define-data-var next-assessment-id uint u1)
(define-data-var next-product-id uint u1)
(define-data-var total-registered-workers uint u0)
(define-data-var total-registered-factories uint u0)

;; ===== PRIVATE FUNCTIONS =====

;; Calculate if wage is fair based on hours and amount
(define-private (is-fair-wage (amount uint) (hours uint))
    (let ((hourly-rate (/ amount hours)))
        (>= hourly-rate minimum-wage-per-hour)
    )
)

;; Calculate compliance score based on working conditions
(define-private (calculate-compliance-score 
    (safety-score uint) 
    (working-hours uint) 
    (has-safety bool) 
    (ventilation bool) 
    (emergency bool))
    (let (
        (safety-points (if (>= safety-score min-safety-score) u25 u0))
        (hours-points (if (<= working-hours max-working-hours-per-day) u25 u0))
        (equipment-points (if has-safety u20 u0))
        (ventilation-points (if ventilation u15 u0))
        (emergency-points (if emergency u15 u0))
    )
    (+ safety-points hours-points equipment-points ventilation-points emergency-points))
)

;; Validate inspector authorization
(define-private (is-authorized-inspector (inspector principal))
    (match (map-get? authorized-inspectors { inspector-address: inspector })
        some-auth (get is-authorized some-auth)
        false
    )
)

;; ===== PUBLIC FUNCTIONS =====

;; Owner functions
(define-public (authorize-inspector (inspector principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set authorized-inspectors 
            { inspector-address: inspector }
            { is-authorized: true, authorization-date: stacks-block-height }
        )
        (ok true)
    )
)

(define-public (revoke-inspector (inspector principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set authorized-inspectors 
            { inspector-address: inspector }
            { is-authorized: false, authorization-date: stacks-block-height }
        )
        (ok true)
    )
)

;; Factory registration and management
(define-public (register-factory 
    (factory-name (string-ascii 64)) 
    (location (string-ascii 128)))
    (let (
        (factory-id (var-get next-factory-id))
    )
        (map-set factories
            { factory-id: factory-id }
            {
                factory-owner: tx-sender,
                factory-name: factory-name,
                location: location,
                certification-level: u0,
                total-workers: u0,
                compliance-score: u0,
                last-inspection: u0,
                is-certified: false
            }
        )
        (var-set next-factory-id (+ factory-id u1))
        (var-set total-registered-factories (+ (var-get total-registered-factories) u1))
        (ok factory-id)
    )
)

;; Worker registration
(define-public (register-worker (factory-id uint))
    (let (
        (worker-id (var-get next-worker-id))
        (factory-exists (is-some (map-get? factories { factory-id: factory-id })))
    )
        (asserts! factory-exists err-not-found)
        (map-set workers
            { worker-id: worker-id }
            {
                worker-address: tx-sender,
                factory-id: factory-id,
                employment-date: stacks-block-height,
                is-active: true,
                total-wage-paid: u0,
                hours-worked: u0,
                safety-violations: u0
            }
        )
        
        ;; Update factory worker count
        (match (map-get? factories { factory-id: factory-id })
            some-factory (begin
                (map-set factories
                    { factory-id: factory-id }
                    (merge some-factory { total-workers: (+ (get total-workers some-factory) u1) })
                )
                true
            )
            false
        )
        
        (var-set next-worker-id (+ worker-id u1))
        (var-set total-registered-workers (+ (var-get total-registered-workers) u1))
        (ok worker-id)
    )
)

;; Record wage payment
(define-public (record-wage-payment 
    (worker-id uint) 
    (amount uint) 
    (hours uint))
    (let (
        (payment-id (var-get next-payment-id))
        (worker-data (unwrap! (map-get? workers { worker-id: worker-id }) err-not-found))
        (factory-id (get factory-id worker-data))
        (hourly-rate (/ amount hours))
        (fair-wage (is-fair-wage amount hours))
    )
        (asserts! (> amount u0) err-invalid-input)
        (asserts! (> hours u0) err-invalid-input)
        (asserts! (or (is-eq tx-sender (get worker-address worker-data))
                     (is-eq tx-sender contract-owner)) err-unauthorized)
        
        ;; Record the payment
        (map-set wage-payments
            { payment-id: payment-id }
            {
                worker-id: worker-id,
                factory-id: factory-id,
                amount: amount,
                hours-worked: hours,
                payment-date: stacks-block-height,
                is-fair-wage: fair-wage,
                hourly-rate: hourly-rate
            }
        )
        
        ;; Update worker totals
        (map-set workers
            { worker-id: worker-id }
            (merge worker-data {
                total-wage-paid: (+ (get total-wage-paid worker-data) amount),
                hours-worked: (+ (get hours-worked worker-data) hours)
            })
        )
        
        (var-set next-payment-id (+ payment-id u1))
        (ok payment-id)
    )
)

;; Assess working conditions
(define-public (assess-working-conditions
    (factory-id uint)
    (safety-score uint)
    (working-hours-per-day uint)
    (has-safety-equipment bool)
    (ventilation-adequate bool)
    (emergency-protocols bool))
    (let (
        (assessment-id (var-get next-assessment-id))
        (factory-exists (is-some (map-get? factories { factory-id: factory-id })))
        (compliance-score (calculate-compliance-score 
            safety-score working-hours-per-day 
            has-safety-equipment ventilation-adequate emergency-protocols))
        (is-compliant (>= compliance-score u75))
    )
        (asserts! factory-exists err-not-found)
        (asserts! (is-authorized-inspector tx-sender) err-unauthorized)
        (asserts! (<= safety-score u100) err-invalid-input)
        (asserts! (> working-hours-per-day u0) err-invalid-input)
        
        ;; Record the assessment
        (map-set working-conditions
            { assessment-id: assessment-id }
            {
                factory-id: factory-id,
                inspector-address: tx-sender,
                safety-score: safety-score,
                working-hours-per-day: working-hours-per-day,
                has-safety-equipment: has-safety-equipment,
                ventilation-adequate: ventilation-adequate,
                emergency-protocols: emergency-protocols,
                assessment-date: stacks-block-height,
                overall-compliance: is-compliant
            }
        )
        
        ;; Update factory compliance data
        (match (map-get? factories { factory-id: factory-id })
            some-factory (begin
                (map-set factories
                    { factory-id: factory-id }
                    (merge some-factory {
                        compliance-score: compliance-score,
                        last-inspection: stacks-block-height,
                        is-certified: is-compliant
                    })
                )
                true
            )
            false
        )
        
        (var-set next-assessment-id (+ assessment-id u1))
        (ok assessment-id)
    )
)

;; Register product with traceability
(define-public (register-product
    (factory-id uint)
    (product-name (string-ascii 64))
    (worker-ids (list 20 uint))
    (total-labor-cost uint))
    (let (
        (product-id (var-get next-product-id))
        (factory-data (unwrap! (map-get? factories { factory-id: factory-id }) err-not-found))
        (is-factory-owner (is-eq tx-sender (get factory-owner factory-data)))
        (fair-trade-cert (get is-certified factory-data))
    )
        (asserts! is-factory-owner err-unauthorized)
        (asserts! (> total-labor-cost u0) err-invalid-input)
        
        (map-set products
            { product-id: product-id }
            {
                factory-id: factory-id,
                product-name: product-name,
                production-date: stacks-block-height,
                worker-ids: worker-ids,
                total-labor-cost: total-labor-cost,
                fair-trade-certified: fair-trade-cert,
                quality-score: (get compliance-score factory-data)
            }
        )
        
        (var-set next-product-id (+ product-id u1))
        (ok product-id)
    )
)

;; ===== READ-ONLY FUNCTIONS =====

;; Get worker information
(define-read-only (get-worker (worker-id uint))
    (map-get? workers { worker-id: worker-id })
)

;; Get factory information
(define-read-only (get-factory (factory-id uint))
    (map-get? factories { factory-id: factory-id })
)

;; Get wage payment information
(define-read-only (get-wage-payment (payment-id uint))
    (map-get? wage-payments { payment-id: payment-id })
)

;; Get working conditions assessment
(define-read-only (get-working-conditions (assessment-id uint))
    (map-get? working-conditions { assessment-id: assessment-id })
)

;; Get product information
(define-read-only (get-product (product-id uint))
    (map-get? products { product-id: product-id })
)

;; Get inspector authorization status
(define-read-only (get-inspector-status (inspector principal))
    (map-get? authorized-inspectors { inspector-address: inspector })
)

;; Get registry statistics
(define-read-only (get-registry-stats)
    {
        total-workers: (var-get total-registered-workers),
        total-factories: (var-get total-registered-factories),
        next-worker-id: (var-get next-worker-id),
        next-factory-id: (var-get next-factory-id),
        contract-owner: contract-owner
    }
)
