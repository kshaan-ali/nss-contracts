// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Importing required libraries and interfaces from OpenZeppelin
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// VaultFactory: Manages NFT fractionalization, offers, and transactions
contract VaultFactory is Ownable, ERC721Holder, ReentrancyGuard {

    // Define possible offer states
    enum State {
        inactive,    // No active offer
        activeOffer  // Offer is active
    }

    // Using Counters library to manage vault IDs
    using Counters for Counters.Counter;
    
    // Structure to store vault details
    struct Vault {
        address collection;                 // NFT collection address
        uint256 tokenId;                    // ID of the NFT
        address owner;                      // Owner of the NFT
        address fractionalTokenAddress;     // Address of the ERC20 token created for fractional ownership
        State sellingState;                 // Current offer state
        uint256 offerPrice;                 // Price for a specified percentage of shares
        uint256 offerTime;                  // Time frame for accepting the offer
        address offerBuyer;                 // Buyer making the offer
        mapping(address => uint256) acceptedOffers; // Tracks share acceptance for each address
        uint256 totalAcceptedShares;        // Total shares accepted for sale
        address[] tokenHolders;             // List of token holders
        address[] royaltyReceivers;         // List of addresses to receive royalties
    }

    // Mapping of vaults indexed by their unique ID
    mapping(uint256 => Vault) public vaults;

    // Counter to keep track of the total number of vaults
    Counters.Counter public vaultCounter;

    // Royalty percentage in basis points (1000 = 10%)
    uint256 private constant royaltyPercentage = 1000;

    // Events to log key actions
    event VaultCreated(uint256 indexed vaultId, address collection, uint256 tokenId, address owner);
    event OfferMade(uint256 indexed vaultId, uint256 offerPrice, address offerBuyer);
    event OfferAccepted(uint256 indexed vaultId, uint256 totalPaid);

    constructor() Ownable(msg.sender) {}

    // Creates a vault, locks the NFT, and fractionalizes it into ERC20 tokens
    function createVault(
        string memory _name,
        string memory _symbol,
        address _collection,
        uint256 _tokenId
    ) external onlyOwner {
        vaultCounter.increment(); // Start indexing from 1
        uint256 newVaultId = vaultCounter.current();
        address _owner = IERC721(_collection).ownerOf(_tokenId); // Retrieve NFT owner address
        require(IERC721(_collection).ownerOf(_tokenId) != address(this)); // Ensure NFT isn't already fractionalized
        
        // Transfer the NFT to this contract
        IERC721(_collection).safeTransferFrom(_owner, address(this), _tokenId);

        // Initialize vault details
        Vault storage newVault = vaults[newVaultId];
        newVault.collection = _collection;
        newVault.tokenId = _tokenId;
        newVault.owner = _owner;
        newVault.royaltyReceivers.push(_owner);

        // Deploy a new ERC20 token for fractional ownership
        FractionalToken fractionalToken = new FractionalToken(
            _name,
            _symbol,
            1250 * 10**18,
            _owner,
            newVaultId,
            address(this)
        );
        newVault.fractionalTokenAddress = address(fractionalToken);

        emit VaultCreated(newVaultId, _collection, _tokenId, msg.sender);
    }

    // Allows a buyer to make an offer to purchase the fractionalized NFT
    function makeOffer(
        uint256 vaultId,
        uint256 _offerTime
    ) external payable {
        Vault storage vault = vaults[vaultId];
        require(30 days >= _offerTime && _offerTime >= 12 hours); // Validate offer duration
        require(vault.sellingState == State.inactive, "Already active"); // Ensure no active offer
        require(msg.value > 0, "amount<0"); // Ensure offer price is positive

        // Set the offer details
        vault.offerBuyer = msg.sender;
        vault.offerTime = block.timestamp + _offerTime;
        vault.sellingState = State.activeOffer;
        vault.offerPrice = msg.value;

        emit OfferMade(vaultId, msg.value, msg.sender);
    }

    // Retrieves royalty receivers associated with a vault
    function getVaultInfo(uint256 vaultId)
        public
        view
        returns (address[] memory)
    {
        return (vaults[vaultId].royaltyReceivers); // We can return other needed fields as well **like (... , .... , ...)
    }

    // Allows token holders to accept the offer by transferring their tokens
    function acceptOffer(uint256 vaultId, uint256 amountOfShares) external nonReentrant{
        Vault storage vault = vaults[vaultId];
        require(block.timestamp < vault.offerTime); // Ensure offer is still active
        require(
            FractionalToken(vault.fractionalTokenAddress).allowance(
                msg.sender,
                address(this)
            ) ==
                amountOfShares && amountOfShares > 0,
            "Insufficient allowance"
        );

        // Transfer tokens from holder to this contract
        FractionalToken(vault.fractionalTokenAddress).transferFrom(
            msg.sender,
            address(this),
            amountOfShares
        );

        // Track the accepted shares and amount transferred
        vault.acceptedOffers[msg.sender] += amountOfShares;
        vault.totalAcceptedShares += amountOfShares;

        // Adding the offerAccepters address
        vault.tokenHolders.push(msg.sender);

        emit OfferAccepted(vaultId, vault.totalAcceptedShares);
    }

    // Finalizes the offer process, handling fund distribution and transfers
    function endOffer(uint256 vaultId) external nonReentrant {
        Vault storage vault = vaults[vaultId];
        require(block.timestamp > vault.offerTime, "Offer is still active");

        FractionalToken fractionalToken = FractionalToken(
            vault.fractionalTokenAddress
        );

        address buyer = vault.offerBuyer;
        uint256 offerShares = 1250 * 10**18;

        // Logic for handling the offer's outcome
        if (vault.totalAcceptedShares < offerShares) {

            // If not all shares are accepted, refund buyer and revert state
            payable(buyer).transfer(vault.offerPrice);

            for (uint256 i = 0; i < vault.tokenHolders.length; i++) {
                address holder = vault.tokenHolders[i];
                // Check if the holder has accepted any offers
                uint256 amountAccepted = vault.acceptedOffers[holder];
                if (amountAccepted > 0) {
                    // Transfer the accepted tokens back to the holder
                    fractionalToken.transfer(holder, amountAccepted);
                }
                delete vault.acceptedOffers[holder];
            }
            delete vault.tokenHolders;
        } 
        else {
            // Handle full purchase, distribute royalties, and update ownership
            fractionalToken.transfer(buyer, offerShares);

            // Calculate the total royalty amount (10% of salePrice)
            uint256 totalRoyalty = (vault.offerPrice * royaltyPercentage) /
                10000;
            uint256 remainingOfferPrice = vault.offerPrice - totalRoyalty;

            // // Calculate each receiver's share
            uint256 individualRoyalty = totalRoyalty /
                vault.royaltyReceivers.length;

            // Distribute royalty equally to each receiver
            for (uint256 i = 0; i < vault.royaltyReceivers.length; i++) {
                payable(vault.royaltyReceivers[i]).transfer(individualRoyalty);
            }

            //Price of each shares
            uint256 tokenPrice = (remainingOfferPrice * 10**18) / offerShares;

            for (uint256 i = 0; i < vault.tokenHolders.length; i++) {
                address holder = vault.tokenHolders[i];

                // Check if the holder has accepted any offers
                uint256 amountAccepted = vault.acceptedOffers[holder];
                if (amountAccepted > 0) {
                    uint256 payableAmount = (amountAccepted * tokenPrice) /
                        10**18; //Token holder will receive this amount

                    //Send the offered amount payout to the tokenholders
                    payable(holder).transfer(payableAmount);
                }
                delete vault.acceptedOffers[holder];
            } 
            delete vault.tokenHolders;

            //Vault information updation {Owner and Royalty address}
            vault.owner = buyer;
            vault.royaltyReceivers.push(buyer);
            
        }

        // Reset vault offer state
        vault.offerBuyer = address(0);
        vault.totalAcceptedShares = 0;
        vault.offerTime = 0;
        vault.offerPrice = 0;
        vault.sellingState = State.inactive;
    }
}

// FractionalToken: ERC20 implementation for fractional NFT ownership
contract FractionalToken is ERC20, ERC20Permit {
    uint256 internal vaultId;
    address internal vaultAddress;

    // Structure to store sell offers
    struct SellOffer {
        address seller;
        uint256 amount; // Amount of tokens offered
        uint256 price; // Price per token in Wei
    }
    uint256 private activeSellingOffers; // Counter for active selling offers

    address[] public tokenHolders; // List of token holders
    uint256 private constant royaltyPercentage = 1000; // 10% royalty in bips (where, 10%= 1000, 100%= 10000)

    mapping(address => SellOffer) public sellOffers; // Track address to store sell offers

    event TokensListedForSale(
        address indexed seller,
        uint256 amount,
        uint256 price
    );

    event SellOfferCanceled(address indexed seller, uint256 amount);
    event TokensPurchased(
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 totalCost
    );

    constructor(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address _to,
        uint256 _vaultId,
        address _vaultAddress
    ) ERC20(name, symbol) ERC20Permit(name) {
        _mint(_to, totalSupply);
        vaultId = _vaultId;
        vaultAddress = _vaultAddress;
    }

    // Function to get total royalty receivers from the VaultFactory contract
    function getRoyaltyReceivers() public view returns (address[] memory) {

        // Retrieve the royalty receivers from VaultFactory via getVaultInfo
        (address[] memory royaltyReceivers) = VaultFactory(vaultAddress).getVaultInfo(
            vaultId
        );

        return royaltyReceivers;
    }

    // ------------------- Selling Functionality -----------------------

    /* 
    Allows a shareholder to list tokens for sale at a specified price
    _amount The number of tokens to sell.
    _price The price per token the seller wants to sell for. */

    function sellTokens(uint256 _amount, uint256 _price) external {
        require(
            balanceOf(msg.sender) >= _amount && balanceOf(msg.sender) > 0,
            "Insufficient balance"
        );
        SellOffer storage selloffer = sellOffers[msg.sender];

        // Already listed as seller
        if (selloffer.amount > 0) {
            selloffer.amount += _amount;
            selloffer.price = _price;

            // Transfer tokens to contract to hold them in escrow for sale
            _transfer(msg.sender, address(this), _amount);

            emit TokensListedForSale(
                msg.sender,
                selloffer.amount + _amount,
                _price
            );
        }
        //Listed as seller for the first time
        else {
            // Transfer tokens to contract to hold them in escrow for sale
            _transfer(msg.sender, address(this), _amount);

            // Create a new sell offer
            sellOffers[msg.sender] = SellOffer(msg.sender, _amount, _price);
            activeSellingOffers++;

            // Adding the seller's address
            tokenHolders.push(msg.sender);

            emit TokensListedForSale(msg.sender, _amount, _price);
        }
    }

    /*
    Allows a seller to cancel their sell offer.
    offerId The ID of the sell offer to cancel. */

    function cancelSellOffer() external {
        require(
            sellOffers[msg.sender].seller == msg.sender,
            "Not the seller of this offer"
        );

        // Return tokens to the seller
        _transfer(address(this), msg.sender, sellOffers[msg.sender].amount);
        activeSellingOffers--;

        emit SellOfferCanceled(msg.sender, sellOffers[msg.sender].amount);

        // Delete the offer
        delete sellOffers[msg.sender];
    }

    // ------------------- Buying Functionality -----------------------

    /*
    Allows a buyer to purchase tokens from the available sell offers, they can check all the avaiable offers and choose one
    _seller The address of the seller who has listed their tokens for sale.
    Allows a buyer to purchase tokens from the available sell offers, starting with the lowest price. */

    function buyTokens(address _seller) external payable {
        SellOffer storage selloffer = sellOffers[_seller];

        // Previously it was _amount ** purchasing token amount
        uint256 totalTransferableToken = (msg.value * 10**18) / selloffer.price; 

        // the total amount of the sold tokens in matic
        uint256 totalPayable = msg.value; 

        // Check to see if msg.value is greater than 0
        require(totalPayable >= 0, "Insufficient funds");

        require(
            totalTransferableToken <= selloffer.amount,
            "Enter a valid amount"
        );

        // Retrieve the royalty receivers from VaultFactory
        address[] memory royaltyReceivers = getRoyaltyReceivers();

        // Calculate the total royalty amount (10% of salePrice)
        uint256 totalRoyalty = (totalPayable * royaltyPercentage) / 10000;
        uint256 remainingPayable = totalPayable - totalRoyalty;

        // Calculate each receiver's share
        uint256 individualRoyalty = totalRoyalty / royaltyReceivers.length;

        // Distribute royalty equally to each receiver
        for (uint256 i = 0; i < royaltyReceivers.length; i++) {
            payable(royaltyReceivers[i]).transfer(individualRoyalty);
        }

        //  Transfer tokens from contract to the buyer
        _transfer(address(this), msg.sender, totalTransferableToken);
        selloffer.amount -= totalTransferableToken;

        // Pay the seller the total amount for the sold tokens
        payable(_seller).transfer(remainingPayable);

        // Delete the seller details who has sold all his tokens
        if (selloffer.amount == 0) {
            delete sellOffers[_seller];
            activeSellingOffers--;
        }

        // Emit an event for successful token purchase
        emit TokensPurchased(
            msg.sender,
            selloffer.seller,
            totalTransferableToken,
            totalPayable
        );
    }

    // ------------------- Calling Functions -----------------------
    
    // Returns number of tokenholder present
    function getTotalTokenHolder() public view returns (uint256){
        return tokenHolders.length;
    }
    /*
    Gets the total number of sell offers. */

    function getTotalSellOffers() public view returns (uint256) {
        return activeSellingOffers;
    }

    /**
    Gets the details of a sell offer.
    @return seller Address of the seller
    @return amount Amount of tokens for sale
    @return price Price per token in Wei */

    function getSellOffer(uint256 num)
        public
        view
        returns (
            address seller,
            uint256 amount,
            uint256 price
        )
    {
        SellOffer storage offer = sellOffers[tokenHolders[num]];
        return (offer.seller, offer.amount, offer.price);
    }
}