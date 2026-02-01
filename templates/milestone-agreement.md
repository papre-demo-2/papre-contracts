# Software Contractor Milestone Agreement

**Agreement ID:** This Agreement is recorded on-chain upon execution.

**Effective Date:** {Effective Date: date: Date the agreement becomes effective}

---

## 1. Parties

This Software Contractor Milestone Agreement ("Agreement") is entered into by and between:

**Client:**
- Company/Individual: {Client Name: string: Legal name of the client or company}
- Primary Contact: {Client Contact: string: Name of primary contact person}
- Email: {Client Email: string: Client contact email address}
- Wallet Address: {Client Address: address: The wallet address that will fund this agreement: _client: none}

**Contractor:**
- Company/Individual: {Contractor Name: string: Legal name of the contractor or company}
- Primary Contact: {Contractor Contact: string: Name of primary contact person}
- Email: {Contractor Email: string: Contractor contact email address}
- Wallet Address: {Contractor Address: address: The wallet address that will receive milestone payments: _contractor: none}

The Client and Contractor are collectively referred to as the "Parties."

---

## 2. Project Overview

**Project Name:** {Project Name: string: Name or title of the project}

**Project Start Date:** {Start Date: date: Expected project start date}

**Project End Date:** {End Date: date: Expected project completion date}

**Project Description:**

{Project Description: string: Detailed description of the software project and its objectives}

---

## 3. Milestones and Payment Schedule

The Contractor agrees to complete the following milestones. Payment for each milestone shall be released from escrow upon the Client's approval of the completed deliverable.

{Milestones: milestones: List of project milestones with deliverables, amounts, and deadlines: _milestones: none}

**Payment Token:** {Payment Token: address: Token address for payment (0x0 for native ETH): _paymentToken: none}

**Currency:** {Currency Symbol: string: Currency symbol (ETH, USDC, etc.)}

### Payment Terms

1. The Client shall deposit the total project amount into escrow upon signing this Agreement.
2. Upon completion of each milestone, the Contractor shall submit the deliverable for review.
3. The Client has {Review Period: integer: Number of days to review submissions} calendar days to approve or dispute each submitted milestone.
4. If no action is taken within the review period, the milestone shall be deemed approved.
5. Upon approval, the corresponding payment amount shall be automatically released to the Contractor.

---

## 4. Scope of Work

### 4.1 Deliverables

The Contractor shall deliver the work as specified in each milestone above. All deliverables shall:

- Meet the specifications described in the milestone description
- Be delivered in a professional, workmanlike manner
- Comply with industry-standard coding practices and documentation requirements
- Include any necessary documentation, as mutually agreed

### 4.2 Change Requests

Any changes to the scope of work must be agreed upon by both Parties. Material changes may require:

- Amendment to this Agreement
- Adjustment of milestone amounts or deadlines
- Creation of additional milestones

---

## 5. Intellectual Property

### 5.1 Ownership

Upon receipt of full payment for each milestone, all intellectual property rights in the deliverables for that milestone shall transfer to the Client, including but not limited to:

- Source code and object code
- Documentation and specifications
- Designs, graphics, and user interfaces
- Any related materials created under this Agreement

### 5.2 Contractor's Reserved Rights

The Contractor retains the right to use:

- General knowledge, skills, and experience gained during the project
- Pre-existing tools, libraries, or frameworks owned by the Contractor (subject to license)
- Open-source components (subject to their respective licenses)

---

## 6. Confidentiality

Both Parties agree to maintain the confidentiality of any proprietary information disclosed during this engagement. This obligation shall survive the termination of this Agreement for a period of **{Confidentiality Period: integer: Years confidentiality obligations remain in effect} year(s)**.

---

## 7. Dispute Resolution

### 7.1 On-Chain Arbitration

Any disputes regarding milestone completion or deliverable quality shall be resolved through the on-chain arbitration mechanism defined in the smart contract.

### 7.2 Arbitration Process

1. Either Party may initiate a dispute within the review period
2. An arbitrator shall be selected according to the contract's arbitration protocol
3. The arbitrator's decision shall be final and binding
4. The arbitrator may approve, reject, or partially approve the disputed milestone

### 7.3 Governing Law

For matters not addressed by on-chain arbitration, this Agreement shall be governed by the laws of {Governing Jurisdiction: string: State or country whose laws govern this agreement}.

---

## 8. Termination

### 8.1 Termination for Convenience

Either Party may terminate this Agreement with **{Termination Notice Days: integer: Days of written notice required for termination} day(s)** written notice. Upon termination:

- The Client shall pay for all approved milestones
- Any milestone in progress shall be evaluated for partial completion
- Unused escrowed funds shall be returned to the Client

### 8.2 Termination for Cause

Either Party may terminate immediately if the other Party:

- Materially breaches this Agreement and fails to cure within {Cure Period Days: integer: Days to cure a breach before termination} day(s) of notice
- Becomes insolvent or files for bankruptcy
- Engages in fraudulent or illegal conduct

---

## 9. Representations and Warranties

### 9.1 Contractor Represents

- The Contractor has the skills, qualifications, and experience to perform the work
- The deliverables will be original work and will not infringe any third-party rights
- The Contractor will comply with all applicable laws and regulations

### 9.2 Client Represents

- The Client has the authority to enter into this Agreement
- The Client will provide timely feedback and approvals
- The Client has secured or will secure the necessary funds to fulfill payment obligations

---

## 10. Limitation of Liability

TO THE MAXIMUM EXTENT PERMITTED BY LAW, NEITHER PARTY SHALL BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES ARISING OUT OF THIS AGREEMENT.

The total liability of either Party shall not exceed the total amount paid or payable under this Agreement.

---

## 11. Miscellaneous

### 11.1 Entire Agreement

This Agreement, together with the on-chain smart contract, constitutes the entire agreement between the Parties and supersedes all prior negotiations, representations, or agreements.

### 11.2 Amendments

This Agreement may only be amended by mutual written consent of both Parties, which may be recorded on-chain.

### 11.3 Notices

All notices shall be delivered to the wallet addresses specified above or to any updated address provided by a Party.

### 11.4 Severability

If any provision of this Agreement is found to be unenforceable, the remaining provisions shall continue in full force and effect.

---

## 12. Signatures

This Agreement is executed electronically via cryptographic signature on the blockchain. By signing, each Party acknowledges that they have read, understood, and agree to be bound by the terms of this Agreement.

**Client Signature:** Recorded on-chain from {Client Address: address: Client's signing wallet: _client: none}

**Contractor Signature:** Recorded on-chain from {Contractor Address: address: Contractor's signing wallet: _contractor: none}

---

*This document is cryptographically linked to a Papre Agreement smart contract. The on-chain record serves as the authoritative source for milestone status, payments, and dispute resolution.*
