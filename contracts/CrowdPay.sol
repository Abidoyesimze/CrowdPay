// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CrowdPay
 * @dev A decentralized fundraising platform for creating and managing campaigns
 */
contract CrowdPay is ReentrancyGuard, Ownable {
    
    uint256 private _campaignIdCounter;
    
    // Campaign status enum
    enum CampaignStatus {
        Active,
        Successful,
        Failed,
        Withdrawn,
        Cancelled
    }
    
    // Campaign struct
    struct Campaign {
        uint256 id;
        address payable organizer;
        string title;
        string description;
        string imageUrl;
        uint256 goalAmount;
        uint256 raisedAmount;
        uint256 deadline;
        uint256 createdAt;
        CampaignStatus status;
        bool fundsWithdrawn;
        uint256 contributorCount;
    }
    
    // Contribution struct
    struct Contribution {
        address contributor;
        uint256 amount;
        uint256 timestamp;
        string message;
    }
    
    // Mappings
    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => Contribution[]) public campaignContributions;
    mapping(uint256 => mapping(address => uint256)) public contributorAmounts;
    mapping(address => uint256[]) public organizerCampaigns;
    mapping(address => uint256[]) public contributorCampaigns;
    
    // Platform fee (basis points - 250 = 2.5%)
    uint256 public platformFeeBps = 250;
    address payable public feeRecipient;
    
    // Minimum campaign duration (7 days)
    uint256 public constant MIN_CAMPAIGN_DURATION = 7 days;
    
    // Maximum campaign duration (365 days)
    uint256 public constant MAX_CAMPAIGN_DURATION = 365 days;
    
    // Minimum goal amount (0.01 ETH)
    uint256 public constant MIN_GOAL_AMOUNT = 0.01 ether;
    
    // Events
    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed organizer,
        string title,
        uint256 goalAmount,
        uint256 deadline
    );
    
    event ContributionMade(
        uint256 indexed campaignId,
        address indexed contributor,
        uint256 amount,
        string message
    );
    
    event CampaignSuccessful(uint256 indexed campaignId, uint256 totalRaised);
    
    event FundsWithdrawn(
        uint256 indexed campaignId,
        address indexed organizer,
        uint256 amount,
        uint256 platformFee
    );
    
    event RefundClaimed(
        uint256 indexed campaignId,
        address indexed contributor,
        uint256 amount
    );
    
    event CampaignCancelled(uint256 indexed campaignId);
    
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    
    constructor(address payable _feeRecipient) {
        feeRecipient = _feeRecipient;
    }
    
    /**
     * @dev Create a new fundraising campaign
     */
    function createCampaign(
        string memory _title,
        string memory _description,
        string memory _imageUrl,
        uint256 _goalAmount,
        uint256 _durationInDays
    ) external returns (uint256) {
        require(bytes(_title).length > 0, "Title cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");
        require(_goalAmount >= MIN_GOAL_AMOUNT, "Goal amount too low");
        require(_durationInDays >= 7 && _durationInDays <= 365, "Invalid duration");
        
        _campaignIdCounter++;
        uint256 newCampaignId = _campaignIdCounter;
        
        uint256 deadline = block.timestamp + (_durationInDays * 1 days);
        
        campaigns[newCampaignId] = Campaign({
            id: newCampaignId,
            organizer: payable(msg.sender),
            title: _title,
            description: _description,
            imageUrl: _imageUrl,
            goalAmount: _goalAmount,
            raisedAmount: 0,
            deadline: deadline,
            createdAt: block.timestamp,
            status: CampaignStatus.Active,
            fundsWithdrawn: false,
            contributorCount: 0
        });
        
        organizerCampaigns[msg.sender].push(newCampaignId);
        
        emit CampaignCreated(newCampaignId, msg.sender, _title, _goalAmount, deadline);
        
        return newCampaignId;
    }
    
    /**
     * @dev Contribute to a campaign
     */
    function contribute(uint256 _campaignId, string memory _message) 
        external 
        payable 
        nonReentrant 
    {
        require(msg.value > 0, "Contribution must be greater than 0");
        require(_campaignId <= _campaignIdCounter, "Campaign does not exist");
        
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.status == CampaignStatus.Active, "Campaign not active");
        require(block.timestamp < campaign.deadline, "Campaign deadline passed");
        require(msg.sender != campaign.organizer, "Organizer cannot contribute");
        
        // Track if this is a new contributor
        bool isNewContributor = contributorAmounts[_campaignId][msg.sender] == 0;
        
        // Update contribution amounts
        contributorAmounts[_campaignId][msg.sender] += msg.value;
        campaign.raisedAmount += msg.value;
        
        // Increment contributor count if new contributor
        if (isNewContributor) {
            campaign.contributorCount++;
            contributorCampaigns[msg.sender].push(_campaignId);
        }
        
        // Record the contribution
        campaignContributions[_campaignId].push(Contribution({
            contributor: msg.sender,
            amount: msg.value,
            timestamp: block.timestamp,
            message: _message
        }));
        
        // Check if campaign goal is reached
        if (campaign.raisedAmount >= campaign.goalAmount) {
            campaign.status = CampaignStatus.Successful;
            emit CampaignSuccessful(_campaignId, campaign.raisedAmount);
        }
        
        emit ContributionMade(_campaignId, msg.sender, msg.value, _message);
    }
    
    /**
     * @dev Withdraw funds from successful campaign (organizer only)
     */
    function withdrawFunds(uint256 _campaignId) external nonReentrant {
        require(_campaignId <= _campaignIdCounter, "Campaign does not exist");
        
        Campaign storage campaign = campaigns[_campaignId];
        require(msg.sender == campaign.organizer, "Only organizer can withdraw");
        require(!campaign.fundsWithdrawn, "Funds already withdrawn");
        require(
            campaign.status == CampaignStatus.Successful || 
            (block.timestamp >= campaign.deadline && campaign.raisedAmount > 0),
            "Cannot withdraw funds yet"
        );
        
        campaign.fundsWithdrawn = true;
        if (campaign.status == CampaignStatus.Active) {
            campaign.status = CampaignStatus.Withdrawn;
        }
        
        uint256 totalAmount = campaign.raisedAmount;
        uint256 platformFee = (totalAmount * platformFeeBps) / 10000;
        uint256 organizerAmount = totalAmount - platformFee;
        
        // Transfer platform fee
        if (platformFee > 0) {
            feeRecipient.transfer(platformFee);
        }
        
        // Transfer remaining funds to organizer
        campaign.organizer.transfer(organizerAmount);
        
        emit FundsWithdrawn(_campaignId, campaign.organizer, organizerAmount, platformFee);
    }
    
    /**
     * @dev Claim refund from failed campaign (contributors only)
     */
    function claimRefund(uint256 _campaignId) external nonReentrant {
        require(_campaignId <= _campaignIdCounter, "Campaign does not exist");
        
        Campaign storage campaign = campaigns[_campaignId];
        require(block.timestamp >= campaign.deadline, "Campaign still active");
        require(campaign.raisedAmount < campaign.goalAmount, "Campaign was successful");
        require(!campaign.fundsWithdrawn, "Funds already withdrawn");
        
        uint256 contributedAmount = contributorAmounts[_campaignId][msg.sender];
        require(contributedAmount > 0, "No contribution found");
        
        // Update campaign status if first refund
        if (campaign.status == CampaignStatus.Active) {
            campaign.status = CampaignStatus.Failed;
        }
        
        // Reset contributor amount to prevent double refunds
        contributorAmounts[_campaignId][msg.sender] = 0;
        campaign.raisedAmount -= contributedAmount;
        
        // Transfer refund
        payable(msg.sender).transfer(contributedAmount);
        
        emit RefundClaimed(_campaignId, msg.sender, contributedAmount);
    }
    
    /**
     * @dev Cancel campaign (organizer only, before any contributions)
     */
    function cancelCampaign(uint256 _campaignId) external {
        require(_campaignId <= _campaignIdCounter, "Campaign does not exist");
        
        Campaign storage campaign = campaigns[_campaignId];
        require(msg.sender == campaign.organizer, "Only organizer can cancel");
        require(campaign.status == CampaignStatus.Active, "Campaign not active");
        require(campaign.raisedAmount == 0, "Cannot cancel campaign with contributions");
        
        campaign.status = CampaignStatus.Cancelled;
        
        emit CampaignCancelled(_campaignId);
    }
    
    /**
     * @dev Get campaign details
     */
    function getCampaign(uint256 _campaignId) 
        external 
        view 
        returns (Campaign memory) 
    {
        require(_campaignId <= _campaignIdCounter, "Campaign does not exist");
        return campaigns[_campaignId];
    }
    
    /**
     * @dev Get campaign contributions
     */
    function getCampaignContributions(uint256 _campaignId) 
        external 
        view 
        returns (Contribution[] memory) 
    {
        require(_campaignId <= _campaignIdCounter, "Campaign does not exist");
        return campaignContributions[_campaignId];
    }
    
    /**
     * @dev Get campaigns created by organizer
     */
    function getOrganizerCampaigns(address _organizer) 
        external 
        view 
        returns (uint256[] memory) 
    {
        return organizerCampaigns[_organizer];
    }
    
    /**
     * @dev Get campaigns contributed to by user
     */
    function getContributorCampaigns(address _contributor) 
        external 
        view 
        returns (uint256[] memory) 
    {
        return contributorCampaigns[_contributor];
    }
    
    /**
     * @dev Get total number of campaigns
     */
    function getTotalCampaigns() external view returns (uint256) {
        return _campaignIdCounter;
    }
    
    /**
     * @dev Get contributor's contribution amount for a campaign
     */
    function getContributorAmount(uint256 _campaignId, address _contributor) 
        external 
        view 
        returns (uint256) 
    {
        return contributorAmounts[_campaignId][_contributor];
    }
    
    /**
     * @dev Check if campaign deadline has passed
     */
    function isDeadlinePassed(uint256 _campaignId) external view returns (bool) {
        require(_campaignId <= _campaignIdCounter, "Campaign does not exist");
        return block.timestamp >= campaigns[_campaignId].deadline;
    }
    
    /**
     * @dev Check if campaign goal is reached
     */
    function isGoalReached(uint256 _campaignId) external view returns (bool) {
        require(_campaignId <= _campaignIdCounter, "Campaign does not exist");
        Campaign memory campaign = campaigns[_campaignId];
        return campaign.raisedAmount >= campaign.goalAmount;
    }
    
    // Admin functions
    
    /**
     * @dev Update platform fee (owner only)
     */
    function updatePlatformFee(uint256 _newFeeBps) external onlyOwner {
        require(_newFeeBps <= 1000, "Fee cannot exceed 10%"); // Max 10%
        uint256 oldFee = platformFeeBps;
        platformFeeBps = _newFeeBps;
        emit PlatformFeeUpdated(oldFee, _newFeeBps);
    }
    
    /**
     * @dev Update fee recipient (owner only)
     */
    function updateFeeRecipient(address payable _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid recipient address");
        feeRecipient = _newRecipient;
    }
    
    /**
     * @dev Emergency withdraw (owner only) - for stuck funds
     */
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    // View functions for campaign statistics
    
    /**
     * @dev Get campaign statistics
     */
    function getCampaignStats(uint256 _campaignId) 
        external 
        view 
        returns (
            uint256 raisedAmount,
            uint256 goalAmount,
            uint256 contributorCount,
            uint256 timeRemaining,
            bool isGoalReached,
            bool isDeadlinePassed
        ) 
    {
        require(_campaignId <= _campaignIds.current(), "Campaign does not exist");
        Campaign memory campaign = campaigns[_campaignId];
        
        raisedAmount = campaign.raisedAmount;
        goalAmount = campaign.goalAmount;
        contributorCount = campaign.contributorCount;
        timeRemaining = campaign.deadline > block.timestamp ? 
            campaign.deadline - block.timestamp : 0;
        isGoalReached = campaign.raisedAmount >= campaign.goalAmount;
        isDeadlinePassed = block.timestamp >= campaign.deadline;
    }
    
    /**
     * @dev Get platform statistics
     */
    function getPlatformStats() 
        external 
        view 
        returns (
            uint256 totalCampaigns,
            uint256 totalRaised,
            uint256 totalContributions
        ) 
    {
        totalCampaigns = _campaignIdCounter;
        
        for (uint256 i = 1; i <= totalCampaigns; i++) {
            totalRaised += campaigns[i].raisedAmount;
            totalContributions += campaignContributions[i].length;
        }
    }
}