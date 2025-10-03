;; FairTrade Label Verification Smart Contract
;; QR code verification system confirming genuine fair trade certification at retail level
;; Provides anti-counterfeiting measures and consumer transparency

;; ===== CONSTANTS =====
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-found (err u201))
(define-constant err-already-exists (err u202))
(define-constant err-invalid-input (err u203))
(define-constant err-unauthorized (err u204))
(define-constant err-expired-label (err u205))
(define-constant err-revoked-label (err u206))
(define-constant err-invalid-qr-code (err u207))

;; Label validity period (in blocks - approximately 1 year)
(define-constant label-validity-period u52560)

;; Minimum compliance score required for certification
(define-constant min-compliance-score u75)

;; ===== DATA STRUCTURES =====

;; QR code registry for authentic labels
(define-map qr-labels
    { qr-hash: (buff 32) }
    {
        product-id: uint,
        factory-id: uint,
        issuer-address: principal,
        creation-date: uint,
        expiry-date: uint,
        is-active: bool,
        verification-count: uint,
        last-verified: uint,
        compliance-score: uint
    }
)

;; Product certification records
(define-map product-certifications
    { product-id: uint }
    {
        factory-id: uint,
        product-name: (string-ascii 64),
        certification-level: uint,
        issuer-address: principal,
        issue-date: uint,
        expiry-date: uint,
        compliance-score: uint,
        labor-standards-met: bool,
        environmental-standards-met: bool,
        social-standards-met: bool,
        is-certified: bool,
        total-verifications: uint
    }
)

;; Authorized certification issuers
(define-map authorized-issuers
    { issuer-address: principal }
    {
        organization-name: (string-ascii 128),
        is-authorized: bool,
        authorization-date: uint,
        issued-certificates: uint,
        revoked-certificates: uint
    }
)

;; Verification history and analytics
(define-map verification-history
    { verification-id: uint }
    {
        qr-hash: (buff 32),
        verifier-address: principal,
        verification-date: uint,
        location-hash: (buff 32),
        device-info: (string-ascii 64),
        verification-result: bool,
        compliance-check: bool
    }
)

;; Consumer verification rewards
(define-map consumer-rewards
    { consumer-address: principal }
    {
        total-verifications: uint,
        reward-points: uint,
        first-verification: uint,
        last-verification: uint,
        unique-products-verified: uint
    }
)

;; Fraud reports and flagged labels
(define-map fraud-reports
    { report-id: uint }
    {
        qr-hash: (buff 32),
        reporter-address: principal,
        report-date: uint,
        fraud-type: uint,
        evidence-hash: (buff 32),
        is-verified: bool,
        reward-claimed: bool
    }
)

;; ===== DATA VARIABLES =====
(define-data-var next-product-id uint u1)
(define-data-var next-verification-id uint u1)
(define-data-var next-report-id uint u1)
(define-data-var total-labels-issued uint u0)
(define-data-var total-verifications uint u0)
(define-data-var total-fraud-reports uint u0)
(define-data-var verification-reward-rate uint u10)

;; ===== PRIVATE FUNCTIONS =====

;; Generate QR hash from product data
(define-private (generate-qr-hash (product-id uint) (factory-id uint) (timestamp uint))
    (keccak256 (concat (concat 
        (unwrap-panic (to-consensus-buff? product-id))
        (unwrap-panic (to-consensus-buff? factory-id)))
        (unwrap-panic (to-consensus-buff? timestamp))
    ))
)

;; Check if label is still valid
(define-private (is-label-valid (creation-date uint) (expiry-date uint))
    (and 
        (<= creation-date stacks-block-height)
        (> expiry-date stacks-block-height)
    )
)

;; Calculate certification level based on compliance scores
(define-private (calculate-certification-level 
    (compliance-score uint) 
    (labor-standards bool) 
    (environmental-standards bool) 
    (social-standards bool))
    (let (
        (base-score (if (>= compliance-score min-compliance-score) u50 u0))
        (labor-points (if labor-standards u20 u0))
        (env-points (if environmental-standards u15 u0))
        (social-points (if social-standards u15 u0))
    )
    (+ base-score labor-points env-points social-points))
)

;; Validate issuer authorization
(define-private (is-authorized-issuer (issuer principal))
    (match (map-get? authorized-issuers { issuer-address: issuer })
        some-issuer (get is-authorized some-issuer)
        false
    )
)

;; ===== PUBLIC FUNCTIONS =====

;; Owner functions
(define-public (authorize-issuer 
    (issuer principal) 
    (organization-name (string-ascii 128)))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-none (map-get? authorized-issuers { issuer-address: issuer })) err-already-exists)
        (map-set authorized-issuers
            { issuer-address: issuer }
            {
                organization-name: organization-name,
                is-authorized: true,
                authorization-date: stacks-block-height,
                issued-certificates: u0,
                revoked-certificates: u0
            }
        )
        (ok true)
    )
)

(define-public (revoke-issuer (issuer principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (match (map-get? authorized-issuers { issuer-address: issuer })
            some-issuer (begin
                (map-set authorized-issuers
                    { issuer-address: issuer }
                    (merge some-issuer { is-authorized: false })
                )
                true
            )
            false
        )
        (ok true)
    )
)

(define-public (update-reward-rate (new-rate uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= new-rate u100) err-invalid-input)
        (var-set verification-reward-rate new-rate)
        (ok true)
    )
)

;; Issue fair trade certification
(define-public (issue-certification
    (factory-id uint)
    (product-name (string-ascii 64))
    (compliance-score uint)
    (labor-standards-met bool)
    (environmental-standards-met bool)
    (social-standards-met bool))
    (let (
        (product-id (var-get next-product-id))
        (cert-level (calculate-certification-level 
            compliance-score labor-standards-met 
            environmental-standards-met social-standards-met))
        (is-certified (>= cert-level u75))
        (expiry-date (+ stacks-block-height label-validity-period))
    )
        (asserts! (is-authorized-issuer tx-sender) err-unauthorized)
        (asserts! (<= compliance-score u100) err-invalid-input)
        (asserts! (> factory-id u0) err-invalid-input)
        
        ;; Create product certification record
        (map-set product-certifications
            { product-id: product-id }
            {
                factory-id: factory-id,
                product-name: product-name,
                certification-level: cert-level,
                issuer-address: tx-sender,
                issue-date: stacks-block-height,
                expiry-date: expiry-date,
                compliance-score: compliance-score,
                labor-standards-met: labor-standards-met,
                environmental-standards-met: environmental-standards-met,
                social-standards-met: social-standards-met,
                is-certified: is-certified,
                total-verifications: u0
            }
        )
        
        ;; Update issuer statistics
        (match (map-get? authorized-issuers { issuer-address: tx-sender })
            some-issuer (begin
                (map-set authorized-issuers
                    { issuer-address: tx-sender }
                    (merge some-issuer { 
                        issued-certificates: (+ (get issued-certificates some-issuer) u1) 
                    })
                )
                true
            )
            false
        )
        
        (var-set next-product-id (+ product-id u1))
        (var-set total-labels-issued (+ (var-get total-labels-issued) u1))
        (ok product-id)
    )
)

;; Generate QR label for certified product
(define-public (generate-qr-label (product-id uint))
    (let (
        (cert-data (unwrap! (map-get? product-certifications { product-id: product-id }) err-not-found))
        (qr-hash (generate-qr-hash product-id (get factory-id cert-data) stacks-block-height))
        (is-cert-owner (is-eq tx-sender (get issuer-address cert-data)))
    )
        (asserts! is-cert-owner err-unauthorized)
        (asserts! (get is-certified cert-data) err-unauthorized)
        (asserts! (is-none (map-get? qr-labels { qr-hash: qr-hash })) err-already-exists)
        
        ;; Create QR label record
        (map-set qr-labels
            { qr-hash: qr-hash }
            {
                product-id: product-id,
                factory-id: (get factory-id cert-data),
                issuer-address: tx-sender,
                creation-date: stacks-block-height,
                expiry-date: (get expiry-date cert-data),
                is-active: true,
                verification-count: u0,
                last-verified: u0,
                compliance-score: (get compliance-score cert-data)
            }
        )
        
        (ok qr-hash)
    )
)

;; Verify QR label authenticity
(define-public (verify-qr-label 
    (qr-hash (buff 32))
    (location-hash (buff 32))
    (device-info (string-ascii 64)))
    (let (
        (verification-id (var-get next-verification-id))
        (label-data (unwrap! (map-get? qr-labels { qr-hash: qr-hash }) err-not-found))
        (is-valid (is-label-valid (get creation-date label-data) (get expiry-date label-data)))
        (is-active (get is-active label-data))
        (verification-result (and is-valid is-active))
        (compliance-check (>= (get compliance-score label-data) min-compliance-score))
    )
        (asserts! verification-result err-expired-label)
        
        ;; Record verification
        (map-set verification-history
            { verification-id: verification-id }
            {
                qr-hash: qr-hash,
                verifier-address: tx-sender,
                verification-date: stacks-block-height,
                location-hash: location-hash,
                device-info: device-info,
                verification-result: verification-result,
                compliance-check: compliance-check
            }
        )
        
        ;; Update QR label statistics
        (map-set qr-labels
            { qr-hash: qr-hash }
            (merge label-data {
                verification-count: (+ (get verification-count label-data) u1),
                last-verified: stacks-block-height
            })
        )
        
        ;; Update product certification statistics
        (match (map-get? product-certifications { product-id: (get product-id label-data) })
            some-cert (begin
                (map-set product-certifications
                    { product-id: (get product-id label-data) }
                    (merge some-cert { 
                        total-verifications: (+ (get total-verifications some-cert) u1) 
                    })
                )
                true
            )
            false
        )
        
        ;; Update consumer rewards
        (match (map-get? consumer-rewards { consumer-address: tx-sender })
            some-consumer (map-set consumer-rewards
                { consumer-address: tx-sender }
                (merge some-consumer {
                    total-verifications: (+ (get total-verifications some-consumer) u1),
                    reward-points: (+ (get reward-points some-consumer) (var-get verification-reward-rate)),
                    last-verification: stacks-block-height
                })
            )
            (map-set consumer-rewards
                { consumer-address: tx-sender }
                {
                    total-verifications: u1,
                    reward-points: (var-get verification-reward-rate),
                    first-verification: stacks-block-height,
                    last-verification: stacks-block-height,
                    unique-products-verified: u1
                }
            )
        )
        
        (var-set next-verification-id (+ verification-id u1))
        (var-set total-verifications (+ (var-get total-verifications) u1))
        (ok verification-id)
    )
)

;; Report fraudulent label
(define-public (report-fraud
    (qr-hash (buff 32))
    (fraud-type uint)
    (evidence-hash (buff 32)))
    (let (
        (report-id (var-get next-report-id))
    )
        (asserts! (<= fraud-type u5) err-invalid-input)
        
        (map-set fraud-reports
            { report-id: report-id }
            {
                qr-hash: qr-hash,
                reporter-address: tx-sender,
                report-date: stacks-block-height,
                fraud-type: fraud-type,
                evidence-hash: evidence-hash,
                is-verified: false,
                reward-claimed: false
            }
        )
        
        (var-set next-report-id (+ report-id u1))
        (var-set total-fraud-reports (+ (var-get total-fraud-reports) u1))
        (ok report-id)
    )
)

;; Revoke QR label (for authorized issuers)
(define-public (revoke-qr-label (qr-hash (buff 32)))
    (let (
        (label-data (unwrap! (map-get? qr-labels { qr-hash: qr-hash }) err-not-found))
        (is-label-issuer (is-eq tx-sender (get issuer-address label-data)))
    )
        (asserts! (or is-label-issuer (is-eq tx-sender contract-owner)) err-unauthorized)
        
        (map-set qr-labels
            { qr-hash: qr-hash }
            (merge label-data { is-active: false })
        )
        
        (ok true)
    )
)

;; ===== READ-ONLY FUNCTIONS =====

;; Get QR label information
(define-read-only (get-qr-label (qr-hash (buff 32)))
    (map-get? qr-labels { qr-hash: qr-hash })
)

;; Get product certification information
(define-read-only (get-certification (product-id uint))
    (map-get? product-certifications { product-id: product-id })
)

;; Get issuer information
(define-read-only (get-issuer-info (issuer principal))
    (map-get? authorized-issuers { issuer-address: issuer })
)

;; Get verification history
(define-read-only (get-verification (verification-id uint))
    (map-get? verification-history { verification-id: verification-id })
)

;; Get consumer rewards
(define-read-only (get-consumer-rewards (consumer principal))
    (map-get? consumer-rewards { consumer-address: consumer })
)

;; Get fraud report
(define-read-only (get-fraud-report (report-id uint))
    (map-get? fraud-reports { report-id: report-id })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
    {
        total-labels-issued: (var-get total-labels-issued),
        total-verifications: (var-get total-verifications),
        total-fraud-reports: (var-get total-fraud-reports),
        verification-reward-rate: (var-get verification-reward-rate),
        contract-owner: contract-owner
    }
)

;; Batch verification for multiple QR codes
(define-read-only (batch-verify-labels (qr-hashes (list 10 (buff 32))))
    (map get-qr-label qr-hashes)
)
