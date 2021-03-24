pragma solidity ^0.5.6;
pragma experimental ABIEncoderV2;
import "./SafeMath.sol";

contract ERC20Interface {
    function balanceOf(address whom) view public returns (uint);
}


contract HodlLottery{
    //endgame, placebid, eliminate players
    //****************LIBRARY DECLARATIONS************************/
    using SafeMath for uint256;

    //*****************GLOBAL VARIABLES***************************/
    address payable owner;
    uint256 constant private HPB_CONVERSION = 1000000000000000000;
    uint256 ticketFeeWEIMin; 
    uint256 ticketFeeWEIMax;
    uint256 uniquePlayerAddressCount;
    mapping(address  => Player) allPlayersMap;
    mapping(uint256 => address payable) allWinnerMap; //holds winners of game before reward is claimed
    //debug bool createByWGTokenHolder
    bool freezeContract = false;
    address lastWinnerAddress = address(0);
    uint256 lastWinnerAmount;
    //TODO SET THIS BACK FOR MAIN RELEASE
    uint256 ownerMaxTickets;

    Game[] allGames;
    uint32 ownerMaxiumumBids;
    uint32 ownerMaximumGames;
    mapping(address => bytes20) addressToBytesMap;
    //mapping(bytes20 => address) bytesToAddressMap;
    mapping(uint256 => Bid[]) gameBids; //gameid => bids
    
    uint256 activeGameCount; //keep track of how many active games
    
    function getAliasIfSet(address addr) public view returns(bytes20){
        return ( addressToBytesMap[addr] ==  0 ? bytes20(uint160(addr)) : addressToBytesMap[addr]);
    }

    
    function getPlayerInfo(address addr) public view returns(uint256 balance, uint256 lifetimeHPBSpent, uint256 lifetimeHPBGained, uint256 lifetimeGamesPlayed){
        return (allPlayersMap[addr].balance, 
                allPlayersMap[addr].lifetimeHPBSpent, 
                allPlayersMap[addr].lifetimeHPBGained, 
                allPlayersMap[addr].lifetimeGamesPlayed);
    }
    
    function sendHPBToPlayer(address payable addr, uint256 amount) public{
        //requre is redundant with safe math
        if(allPlayersMap[addr].addr == address(0))
        {
            //add player, player doesn't exist yet
            createNewPlayer(addr);
        }
        allPlayersMap[msg.sender].balance = allPlayersMap[msg.sender].balance.sub(amount);
        allPlayersMap[addr].balance = allPlayersMap[addr].balance.add(amount);
        emit SendHPBToPlayer(getAliasIfSet(msg.sender), getAliasIfSet(addr), amount);
        return;
    } 

    //*****************STRUCTS************************************/
    struct TicketInfo{
        uint256 ticketsOwned;
        uint256 ticketsForSale;
    }
    struct Player
    {
        address payable addr; //owner address of player
        uint256 balance; //balance of player
        uint256 lifetimeHPBSpent;
        uint256 lifetimeHPBGained;
        uint256 lifetimeGamesPlayed;
        mapping(uint256 => TicketInfo) playerGameTickets; 
    }
    struct Bid{  
        address payable addr; //owner address of player
        uint256 highestBidWEI;
        uint256 gameID;
    }
        
    struct Game
    {
        uint256 gameID;
        uint256 currentRoundNumber;
        bytes32 name;
        uint256 ticketFee;
        bytes20[8] lastEliminated;
        uint256 minimumTicketCount;
        bool isGameActive;
        bool isGamePending;
        bool isGameComplete;
        bool isEndGameReady;
        bool exists; //if game exists
        uint256 hpbWinnerPool;
        uint256 entryCount;
        address payable vip;
        uint256 ticketCountAtStart;
        uint256 blockCountActionReadyIndex;
        uint256 blockGameDelay;
        uint256 blockRoundDelay;
        address payable[] tickets; //tickets don't really need any other info requiring separate struct
    }
    
    //sending without value will give owner funds
    function() external payable {
        allPlayersMap[owner].balance = allPlayersMap[owner].balance.add(msg.value);
    }
    
    
    //*************************PUBLIC EVENTS*********************************
    event BuyTickets(uint256 gameID, bytes32 gameName, bytes20 sender, uint256 ticketCount, uint256 totalTickets);
    event EndGame(uint256 gameID, bytes32 gameName, bytes20 sender, bytes20 winnerAddress, uint256 hpbWinnerPool); 
    event LeaveGame(uint256 gameID, bytes32 gameName, uint256 ticketsRemaining, bytes20 sender);
    event PlaceBid(uint256 gameID, bytes20 sender, bytes32 gameName, bytes20 oldOwner, bytes20 newOwner, uint256 bidAmount, uint256 newBlockReadyIndex);
    event SellTicketBid(uint256 gameID, bytes32 gameName, bytes20 sender, uint256 startingBid);
    event StartGame(uint256 gameID, bytes32 gameName, bytes20 sender, uint256 playersAtStart, uint256 winnerPool);
    event EliminatePlayers(uint256 gameID, bytes32 gameName, bytes20 sender, bytes20[8] eliminated, uint256 remaining, uint256 actionReady);
    event AnnounceWinner(bytes20 winnerAddress, uint256 gameID, bytes32 gameName, uint256 winnerPool);
    event Deposit(bytes20 sender, uint256 value);
    event CreateNewGame(bytes20 sender, uint256 gameID, bytes32 gameName);
    event Withdraw(bytes20 sender, uint256 value);
    event SetAlias(bytes20 sender, bytes20 aliasName);
    event SendHPBToPlayer(bytes20 sender, bytes20 receiver, uint256 amount);
    //*****************CONTRACT CONSTRUCTOR/DESTRUCTOR***********************/
    constructor() public  {
        owner = msg.sender; //set the owner
        createNewPlayer(owner);
        allGames.length = 0;
        ownerMaxTickets = 65535;

        setTicketFeeRange(HPB_CONVERSION.div(1000), HPB_CONVERSION.mul(1000)); //entry fee range 0.001 - 1000
        ownerMaxiumumBids = 25;
        ownerMaximumGames = 500;
        
    }
    function destroy() payable public{
        require(msg.sender == owner);
        selfdestruct(owner);
    }
    //*****************OWNER ONLY FUNCTIONS***********************/
    //set owner of contract
    function setOwner(address payable newOwner) public{
        require(msg.sender == owner);
        owner = newOwner;
    }

    //sets the entry fee per game
    function setTicketFeeRange(uint256 hpbFeeMin, uint256 hpbFeeMax) public{
        require(msg.sender == owner);
        ticketFeeWEIMin = hpbFeeMin;
        ticketFeeWEIMax = hpbFeeMax;
    }
    //****************GET FUNCTIONS********************************/
    function getTicketFeeWEIRange() public view returns(uint256 minWEI, uint256 maxWEI){
        return (ticketFeeWEIMin, ticketFeeWEIMax);
    }

    //Get the number of players joined in the current round
    function getTicketCount(uint256 gameID) external view returns(uint256){
        return allGames[gameID].tickets.length;
    }
    
    function setMaxTickets(uint256 maxTickets) public{
        require(owner == msg.sender);
        ownerMaxTickets = maxTickets;
    }

    //returns 0 when game is ready to start
    function getBlocksBeforeGameCanStart(uint256 gameID) public view returns(uint256)
    {
        if(allGames[gameID].exists == false || 
           allGames[gameID].isGameActive == true || 
           allGames[gameID].isGamePending == false){
               return 9998;
           }

		if(allGames[gameID].tickets.length < allGames[gameID].minimumTicketCount){
			return 9999;
		}
        if(block.number >= allGames[gameID].blockCountActionReadyIndex){
			return 0;
		}
        else{
			return allGames[gameID].blockCountActionReadyIndex.sub(block.number);
		} 
    }
    //***************MAIN FUNCTIONALITY****************************/
    function getWGTokenBalance() external view returns(uint256){
        return ERC20Interface(0x4040ba3e686dFc53e2e3192F3df433ea2eE54085).balanceOf(msg.sender);     
    }
    
    function buyTickets(uint256 gameID, uint256 ticketCount) public {
        require(ticketCount <= 8 && ticketCount > 0);
        require(allGames[gameID].exists);
        
        require(allGames[gameID].isGameActive == false);
        require(allGames[gameID].isGamePending == true);
        require(allGames[gameID].tickets.length <= ownerMaxTickets);//too many tickets
        require(allPlayersMap[msg.sender].balance >= allGames[gameID].ticketFee.mul(ticketCount));
        
        allPlayersMap[msg.sender].balance = allPlayersMap[msg.sender].balance.sub(allGames[gameID].ticketFee.mul(ticketCount)); //subtract from user balance 
        allPlayersMap[owner].balance = allPlayersMap[owner].balance.add(allGames[gameID].ticketFee.mul(ticketCount).div(50)); //add to owner balance 2%
        
        uint256 winnerPoolAdd = allGames[gameID].ticketFee.mul(49).div(50).mul(ticketCount);
        allGames[gameID].hpbWinnerPool = allGames[gameID].hpbWinnerPool.add(winnerPoolAdd); //98% is assigned to winner pool
        //add 1 to games played
        if(allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned == 0){
            allPlayersMap[msg.sender].lifetimeGamesPlayed = allPlayersMap[msg.sender].lifetimeGamesPlayed.add(1);
        }
        if(allPlayersMap[msg.sender].addr == allGames[gameID].vip && allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned == 0){
            allPlayersMap[msg.sender].lifetimeHPBSpent = allPlayersMap[msg.sender].lifetimeHPBSpent.add(allGames[gameID].ticketFee.mul(ticketCount.sub(1)));
        }
        else
            allPlayersMap[msg.sender].lifetimeHPBSpent = allPlayersMap[msg.sender].lifetimeHPBSpent.add(allGames[gameID].ticketFee.mul(ticketCount));
            
        for(uint256 i = 0; i != ticketCount; i++){
            
            allGames[gameID].tickets.push(msg.sender); 
        }

        allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned = allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned.add(ticketCount);
        allGames[gameID].entryCount = allGames[gameID].entryCount.add(ticketCount);
        emit BuyTickets(gameID, allGames[gameID].name, getAliasIfSet(msg.sender), ticketCount, allGames[gameID].tickets.length);
    }

    //creates new player with zero balance(internal function only)
    function createNewPlayer(address payable addr) internal{
        uniquePlayerAddressCount = uniquePlayerAddressCount.add(1);
        allPlayersMap[addr] = Player(addr, 0, 0, 0, 0);
    }

    function setAlias(bytes20 newAlias) public{
        if(allPlayersMap[msg.sender].addr == address(0))
        {
            //add player, player doesn't exist yet
            createNewPlayer(msg.sender);
        }
        addressToBytesMap[msg.sender] = newAlias;   
        //bytesToAddressMap[newAlias] = msg.sender;
        emit SetAlias(bytes20(uint160(msg.sender)), newAlias);
    }
    
    function deposit() public payable{
        //*TODO*
        require(freezeContract == false);
        require(msg.value > 0);
        //if player does not exist, create a new player
        if(allPlayersMap[msg.sender].addr == address(0))
        {
            //add player, player doesn't exist yet
            createNewPlayer(msg.sender);
        }
        //increase player balance
        allPlayersMap[msg.sender].balance = allPlayersMap[msg.sender].balance.add(msg.value);
        emit Deposit(getAliasIfSet(msg.sender), msg.value);
    }
 
    function getNewGameID() internal view returns(uint256 gameID){
        bool found = false;
        if(allGames.length == 0)
            return 0;
        for(uint256 i = 0; i < allGames.length; i ++)
        {
            if(i >= ownerMaximumGames)
                revert(); //too many active games
            if(allGames[i].isGameComplete == true)
            {
                gameID = i;  
                found = true;
                break;
            }
        }
        if(!found)
            gameID = uint256(allGames.length);
        return gameID;
    }
    
 
    
    function createGame(uint256 _entryFee, uint256 minimumTicketCount, uint256 ticketsToBuy, bytes32 gameName, uint256 gameDelay, uint256 roundDelay) external returns(bool){

        require(freezeContract == false);
        require(_entryFee >= ticketFeeWEIMin && _entryFee <= ticketFeeWEIMax);
        require(ticketsToBuy <= 8);
        require(gameDelay <= 600);
        require(roundDelay <= 60);
        
        
        Game memory newGame;
        newGame.gameID =  getNewGameID(); 
        newGame.ticketFee = _entryFee;
        newGame.name = gameName;
        newGame.blockRoundDelay = roundDelay;
        newGame.blockGameDelay = gameDelay;
        newGame.isGamePending = true;
        newGame.exists = true;
        newGame.minimumTicketCount = minimumTicketCount;
        newGame.blockCountActionReadyIndex = block.number.add(newGame.blockGameDelay);
        
        newGame.lastEliminated = [bytes20(uint160(INVALID_RANDOM)), 
                                  bytes20(uint160(INVALID_RANDOM)),  
                                  bytes20(uint160(INVALID_RANDOM)),
                                  bytes20(uint160(INVALID_RANDOM)), 
                                  bytes20(uint160(INVALID_RANDOM)), 
                                  bytes20(uint160(INVALID_RANDOM)),
                                  bytes20(uint160(INVALID_RANDOM)),
                                  bytes20(uint160(INVALID_RANDOM))];
                                  
        
        if(ERC20Interface(0x4040ba3e686dFc53e2e3192F3df433ea2eE54085).balanceOf(msg.sender) >= 1){
            if(newGame.minimumTicketCount >= 100){
                allPlayersMap[msg.sender].balance = allPlayersMap[msg.sender].balance.add(newGame.ticketFee);
                newGame.vip = msg.sender;
            }
        }
        
        if(newGame.gameID >= allGames.length){
            allGames.push(newGame);    
        }
        else{
            allGames[newGame.gameID] = newGame;
        }
        
        activeGameCount = activeGameCount.add(1);
        emit CreateNewGame(getAliasIfSet(msg.sender), newGame.gameID, newGame.name);
        buyTickets(newGame.gameID, ticketsToBuy);
        //refund cost of one ticket if playercount >= 100 and holds a wgtoken coin

        return true;
    }
    

    //starts the next round of an active game, eliminating players, just use emit todo
    function startNextRound(uint256 gameID) public {
        require(allGames[gameID].exists);
        require(allGames[gameID].isEndGameReady == false);
        require(canStartNextRound(gameID) == true);
        require(allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned > 0);
        clearGameBids(gameID); //clear bids from previous rounds
        
        eliminatePlayers(gameID);

        if(allGames[gameID].tickets.length == 1 || allPlayersMap[allGames[gameID].tickets[0]].playerGameTickets[gameID].ticketsOwned == allGames[gameID].tickets.length){
            allGames[gameID].isEndGameReady = true;
            allGames[gameID].isGameActive = false;
            allWinnerMap[gameID] = allGames[gameID].tickets[0]; //winner is the owner of the last ticket
            emit AnnounceWinner(getAliasIfSet(allGames[gameID].tickets[0]), gameID, allGames[gameID].name, allGames[gameID].hpbWinnerPool);
        }
        else{
            allGames[gameID].blockCountActionReadyIndex = block.number.add(allGames[gameID].blockRoundDelay);
        }
        allGames[gameID].currentRoundNumber = allGames[gameID].currentRoundNumber.add(1);
    }

    
    function endGame(uint256 gameID) public{
        require(allGames[gameID].exists);
        require(allGames[gameID].isEndGameReady == true);
        allGames[gameID].isGameActive = false;
        allGames[gameID].isGamePending = false; 
        allGames[gameID].isGameComplete = true;
        allGames[gameID].exists = false;
        allGames[gameID].isEndGameReady = false;
        
        //if vip user wins, 25% goes to dev
        if(allGames[gameID].vip == allPlayersMap[allGames[gameID].tickets[0]].addr)
        {
            allPlayersMap[owner].balance = allPlayersMap[owner].balance.add(allGames[gameID].hpbWinnerPool.mul(25).div(100)); //25% to dev
            allGames[gameID].hpbWinnerPool = allGames[gameID].hpbWinnerPool.mul(75).div(100); //shrink reward to 75%
            
        }
        emit EndGame(gameID, allGames[gameID].name, getAliasIfSet(msg.sender),  getAliasIfSet(allGames[gameID].tickets[0]), allGames[gameID].hpbWinnerPool); //emit event
        allPlayersMap[allGames[gameID].tickets[0]].lifetimeHPBGained = allPlayersMap[msg.sender].lifetimeHPBGained.add(allGames[gameID].hpbWinnerPool);
        allPlayersMap[allGames[gameID].tickets[0]].balance = allPlayersMap[allGames[gameID].tickets[0]].balance.add(allGames[gameID].hpbWinnerPool);
        allPlayersMap[allGames[gameID].tickets[0]].playerGameTickets[gameID].ticketsOwned = 0; //remove all tickets from last player
        allPlayersMap[allGames[gameID].tickets[0]].playerGameTickets[gameID].ticketsForSale = 0; //remove all tickets from last player
        allGames[gameID].tickets.length = 0;//remove last ticket
        
        
        allGames[gameID].hpbWinnerPool = 0; //reset winner pool
        allWinnerMap[gameID] = address(0); //clear the address
        
        activeGameCount = activeGameCount.sub(1);
        return;
    }
    
    
    //TODO emit eliminated tickets
    function startGame(uint256 gameID) public {
        require(allGames[gameID].exists);
        
        require(allGames[gameID].isGameActive == false);
        require(allGames[gameID].isGamePending == true);
        require(block.number >= allGames[gameID].blockCountActionReadyIndex);
        require(allGames[gameID].tickets.length >= allGames[gameID].minimumTicketCount);
        require(allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned > 0);
 
        //subtract the ticket fee that was refunded from the 100 player game
        if(allGames[gameID].vip != address(0)){
            allPlayersMap[owner].balance = allPlayersMap[owner].balance.sub(allGames[gameID].ticketFee);
        }
        
    //    allGames[gameID].ticketCountAtStart = allGames[gameID].tickets.length;
        

        //shuffleTickets(gameID);
        emit StartGame(gameID, allGames[gameID].name, getAliasIfSet(msg.sender), allGames[gameID].tickets.length, allGames[gameID].hpbWinnerPool);
        allGames[gameID].entryCount = allGames[gameID].tickets.length;
        allGames[gameID].isGamePending = false;
        allGames[gameID].isGameActive = true;
        allGames[gameID].ticketCountAtStart = allGames[gameID].tickets.length; //for calculating how many to eliminate per round
        allGames[gameID].currentRoundNumber = 0;
        startNextRound(gameID);

        allGames[gameID].blockCountActionReadyIndex = block.number.add(allGames[gameID].blockRoundDelay);
        return;
    }
    
    //remove a max of 10 players at a time to opimize gas
    function getNumOfPlayersToEliminate(uint256 gameID) public view returns(uint256){

        uint256 eliminate;
        uint256 ten = 10;
        
        if(allGames[gameID].currentRoundNumber < 10){
            eliminate = allGames[gameID].ticketCountAtStart.div(10);
            if(eliminate.mul(ten.sub(allGames[gameID].currentRoundNumber)) < allGames[gameID].tickets.length){
                eliminate += 1;
            }
        }
        else
            eliminate = 8;
        
        if(allGames[gameID].tickets.length == 2)
            return 1;
        else if(eliminate + 1  >= allGames[gameID].tickets.length) //leave so min of 2 people
            eliminate =  (allGames[gameID].tickets.length - 2);
        else 
            return eliminate;//eliminate=7 length=8  
    }
  
    function getLastEliminated(uint256 gameID) public view returns(bytes20[8] memory){
        return allGames[gameID].lastEliminated;
    }
    
    function eliminatePlayers(uint256 gameID) internal returns(bytes20[8] memory){

        uint256 removed;
        //calculate how many players to eliminate
        uint32 toEliminateCount = uint32(getNumOfPlayersToEliminate(gameID)); 
        bytes20[8] memory tempLastEliminated = getRandomSet(uint8(toEliminateCount), 0,  uint32(allGames[gameID].tickets.length.sub(1)));

        for(uint256 i = 0; i != 8; i++){
            if(uint160(tempLastEliminated[i]) == INVALID_RANDOM){
                allGames[gameID].lastEliminated[i] = bytes20(INVALID_RANDOM);
                continue;
            }
            else{
                //subtract ticket from player
                allPlayersMap[allGames[gameID].tickets[uint160(tempLastEliminated[i])] ].playerGameTickets[gameID].ticketsOwned =  allPlayersMap[allGames[gameID].tickets[uint160(tempLastEliminated[i])] ].playerGameTickets[gameID].ticketsOwned.sub(1);
                
                //if(allPlayersMap[allGames[gameID].tickets[uint160(tempLastEliminated[i])] ].playerGameTickets[gameID].ticketsOwned == 0)
                  //  allPlayersMap[allGames[gameID].tickets[uint160(tempLastEliminated[i])] ].lifetimeGamesPlayed = allPlayersMap[allGames[gameID].tickets[uint160(tempLastEliminated[i])] ].
                 //   lifetimeGamesPlayed.add(1);
                
                allGames[gameID].lastEliminated[i] = getAliasIfSet(   allGames[gameID].tickets[uint160(tempLastEliminated[i])]      );
                allGames[gameID].tickets[uint160(tempLastEliminated[i])] =
                allGames[gameID].tickets[allGames[gameID].tickets.length.sub(removed).sub(1)];
                removed = removed.add(1);
            }
           // allGames[gameID].lastEliminated[removed] = bytes20(INVALID_RANDOM);
        }

        allGames[gameID].tickets.length = allGames[gameID].tickets.length.sub(removed);
        allGames[gameID].entryCount = allGames[gameID].tickets.length;
        emit EliminatePlayers(gameID, allGames[gameID].name, getAliasIfSet(msg.sender),  allGames[gameID].lastEliminated, allGames[gameID].tickets.length, block.number.add(allGames[gameID].blockRoundDelay));

    }
    
    //determines if the next round can be started
    function canStartNextRound(uint256 gameID) internal view returns(bool)
    {
        //cannot start round with no active game
        if(allGames[gameID].exists == false || allGames[gameID].isGameActive == false || allGames[gameID].isGameComplete == true || allGames[gameID].isEndGameReady == true)
        {
            return false;
        }
        if(block.number >= allGames[gameID].blockCountActionReadyIndex)
        {
            return true;
        }
        else
        {
            return false;
        }
    }
    //determines if the game can be started
    function canStartPendingGame(uint256 gameID) internal view returns(bool)
    {
        require(allGames[gameID].exists);
        
        if(allGames[gameID].isGameActive == true)
        {
            return false;
        }
        else if(getBlocksBeforeGameCanStart(gameID) == 0 && allGames[gameID].tickets.length >= allGames[gameID].minimumTicketCount)
        {
            return true;
        }
        else
        {
            return false;
        }
    }
    function withdraw(uint256 quantity) external payable returns(uint256) {

        allPlayersMap[msg.sender].balance = allPlayersMap[msg.sender].balance.sub(quantity);
        allPlayersMap[msg.sender].addr.transfer(quantity);
        emit Withdraw(getAliasIfSet(msg.sender), quantity);
        return allPlayersMap[msg.sender].balance;
    }

/*
    function canBuyTicket(uint256 gameID) internal view returns(bool)
    {
        return (allGames[gameID].exists && allGames[gameID].isGamePending == true && allGames[gameID].isGameComplete == false);
    }
    */
    function getWinnerPoolWEI(uint256 gameID) external view returns(uint256){
        if(allGames[gameID].exists == false)
            return 0;
        
        return allGames[gameID].hpbWinnerPool;
    }

    uint160 INVALID_RANDOM = 44444444444;
    //generates up to 8 true random number values between mix and max value (0 and FFFF(4,294,967,295) possible) 
    //returns INVALID_RANDOM if generated number has modulo bias (outside of uint32 range of valid values)
    //splits up the block.random into chunks of 8 bytes and returns value
    function getRandomSet(
            uint8 randomNumberCount, uint32 minValue, uint32 maxValue) 
            internal view  returns(bytes20[8] memory  randomNumbers){
              
        require(minValue < maxValue);
        require(randomNumberCount > 0 && randomNumberCount <=8);
        bytes20[8] memory randomNumberSet;
        bytes32 randomNumber =  block.random;
        uint160 possibleValues = (maxValue - minValue) + 1;
        uint32 randVal;
        for(uint8 i = 0; i != randomNumberCount; i++){
               randVal = (uint32(bytes4(randomNumber << 32 * i)));
               if(uint32(randVal) > (4294967295 / uint32(possibleValues)) * uint32(possibleValues))
                    //throw value out because it has modulo bias and makes odds uneven
                    randomNumberSet[i] = bytes20(INVALID_RANDOM);
                else{
                    randomNumberSet[i] = bytes20((randVal % possibleValues) + minValue);
                    possibleValues -= 1; //slightly altered because the range should be deducted by 1 for each call
                }
        }
        //fill rest of values with invalid data
        for(uint8 i = randomNumberCount; i != 8; i++)
            randomNumberSet[i] = bytes20(INVALID_RANDOM);
        
        return randomNumberSet;
    }

    
    function ticketsOwnedInGame(uint256 gameID) public view returns(uint256 entryCount){
        require(allGames[gameID].exists);
        return allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned;
    }
    
    function setContractFreeze(bool freezeState) public{
        require(msg.sender == owner);
        freezeContract = freezeState;
        return;
    }

    function getLastWinnerAddress() public view returns(address addressLastWinner){
        return lastWinnerAddress;
    }
    
    function getLastWinnerAmount() public view returns(uint256){
       return lastWinnerAmount;
    }
    
    function cancelGame(uint256 gameID) private{
        require(allGames[gameID].tickets.length == 0);
        
        allGames[gameID].isGameActive = false;
        allGames[gameID].isGameComplete = true;
        allGames[gameID].isGamePending = false;
        allGames[gameID].exists = false;
        allGames[gameID].entryCount = 0;
        activeGameCount = activeGameCount.sub(1);
    }
    
    function getPlayerCountAlltime() external view returns(uint256 playerCount){
        return uniquePlayerAddressCount;
    }
    

    function leaveGame(uint256 gameID) public{
        require(allGames[gameID].exists == true);
        require(allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned > 0);
        require(allGames[gameID].isGameActive == false);
        require(allGames[gameID].isGamePending == true);
        require(allGames[gameID].isGameComplete == false);
        
        uint256 ticketsRemoved = 0;
 
        uint256 newLength = allGames[gameID].tickets.length.sub(allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned);
        
        address payable[] memory newChain = new address payable[](newLength);
        uint256 j = 0;
        for(uint256 i = 0; i < allGames[gameID].tickets.length; i++){
            
            if(allGames[gameID].tickets[i] != msg.sender){
                newChain[j] = (allGames[gameID].tickets[i]);
                j ++;
            }
        }
        ticketsRemoved = allGames[gameID].tickets.length.sub(newChain.length);
        allGames[gameID].entryCount = allGames[gameID].entryCount.sub(ticketsRemoved);
        allGames[gameID].tickets = newChain; //reassign tickets 

        if(allGames[gameID].tickets.length == 0){
            cancelGame(gameID);
        }
        
        //if VIP member leaving game
        if(allGames[gameID].vip == allPlayersMap[msg.sender].addr){
            allGames[gameID].vip = address(0);
            //refund is one less ticket than paid for
            allPlayersMap[msg.sender].balance = allPlayersMap[msg.sender].balance.add(allGames[gameID].ticketFee.mul(ticketsRemoved.sub(1)));
            allPlayersMap[msg.sender].lifetimeHPBSpent = allPlayersMap[msg.sender].lifetimeHPBSpent.sub(allGames[gameID].ticketFee.mul(allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned.sub(1))); //undo money sepnt
        }
        else{
            allPlayersMap[msg.sender].lifetimeHPBSpent = allPlayersMap[msg.sender].lifetimeHPBSpent.sub(allGames[gameID].ticketFee.mul(allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned)); //undo money sepnt
            allPlayersMap[msg.sender].balance = allPlayersMap[msg.sender].balance.add(allGames[gameID].ticketFee.mul(ticketsRemoved));//add funds back to player account
        }
            allPlayersMap[msg.sender].lifetimeGamesPlayed = allPlayersMap[msg.sender].lifetimeGamesPlayed.sub(1); //undo games played
        allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned = 0;
        allPlayersMap[owner].balance = allPlayersMap[owner].balance.sub(allGames[gameID].ticketFee.mul(ticketsRemoved).div(50)); //remove 2% from owner account
        allGames[gameID].hpbWinnerPool  = allGames[gameID].hpbWinnerPool.sub(allGames[gameID].ticketFee.mul(ticketsRemoved.mul(49)).div(50)); //removed from winner pool
        emit LeaveGame(gameID, allGames[gameID].name, allGames[gameID].tickets.length, getAliasIfSet(msg.sender));
    }
    //===================BIDDING FUCNTIONS=============================
    function sellTicketBid(uint256 gameID, uint256 startingBid) public{
        require(gameID < allGames.length);
        require(allGames[gameID].exists == true);
        require(allGames[gameID].isGameActive == true);
        require(allGames[gameID].isGameComplete == false);
        require(allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned > 
                allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsForSale);
 
 
        allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsForSale = allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsForSale.add(1);
 
        gameBids[gameID].push(Bid(msg.sender, startingBid, gameID));
        emit SellTicketBid(gameID, allGames[gameID].name, getAliasIfSet(msg.sender), startingBid);
    }
    
 
    function clearGameBids(uint256 gameID) private{
        for(uint256 i = 0; i != gameBids[gameID].length; i ++){
            allPlayersMap[gameBids[gameID][i].addr].playerGameTickets[gameID].ticketsForSale = 0;
        }
        gameBids[gameID].length = 0;
    }
    
    function getBids(uint256 gameID, uint256 bidIndex) public view returns(bytes20 ownedaddress, uint256 highestBid){
        
        return (getAliasIfSet(gameBids[gameID][bidIndex].addr), gameBids[gameID][bidIndex].highestBidWEI);
    }
    
    function getBidCount(uint256 gameID) public view returns(uint256 bidCount){
        return gameBids[gameID].length;
    }

    function getPlayerGameInfo(uint256 gameID) public view returns (uint256 ticketsOwned, uint256 ticketsForSale){
        return (allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned,
        allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsForSale);
        
    }
    
    function setMaximumBid(uint32 maximumBids) public{
        require(msg.sender == owner);
        ownerMaxiumumBids = maximumBids;
    }
    function setMaximumGames(uint32 maximumGames) public{
        require(msg.sender == owner);
        ownerMaxiumumBids = maximumGames;
    }
    function getMaximumGames() public view returns(uint256){
        return ownerMaxiumumBids;
    }
    function getMaximumBids() public view returns(uint256){
        return ownerMaxiumumBids;
    }
    
    function placeBid(uint256 gameID, uint256 bidAmount) public returns(bool){
    //returns true if bid was accepted otherwise returns false
    //there is the same 2% fee for tickets bought from aution as buying originally.
        require(allGames[gameID].exists == true);
        require(allGames[gameID].isGameActive == true);
        require(allGames[gameID].isGameComplete == false);
        require(bidAmount <= allPlayersMap[msg.sender].balance);
        require(gameBids[gameID].length <= ownerMaxiumumBids); //optimize gas limit
        uint256 fee = allGames[gameID].ticketFee.div(50); // same 2% fee
        address payable oldOwner;
       

        bool found = false;
        uint256 lowestSellIndex = 0;
        //find lowest sale that meets requirements
        //DEBUG NEED TO OPTIMIZE
        for(uint256 i = 0; i != gameBids[gameID].length; i ++){

            if(bidAmount > gameBids[gameID][i].highestBidWEI && gameBids[gameID][i].highestBidWEI <= gameBids[gameID][lowestSellIndex].highestBidWEI && gameBids[gameID][i].addr != msg.sender){
                lowestSellIndex = i;
                found = true;
            }
            
        }
        if(found){
            //inspect fees DEBUGG
            allPlayersMap[msg.sender].balance = allPlayersMap[msg.sender].balance.sub(bidAmount.add(fee)); //remove from buyer account
            allPlayersMap[owner].balance = allPlayersMap[owner].balance.add(fee); //add 2% to owner
            allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned = allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsOwned.add(1); //add ticket to new owner
            allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsForSale = allPlayersMap[msg.sender].playerGameTickets[gameID].ticketsForSale.add(1); //add ticket to new owner for sale as well
 
            allPlayersMap[gameBids[gameID][lowestSellIndex].addr].playerGameTickets[gameID].ticketsOwned = allPlayersMap[gameBids[gameID][lowestSellIndex].addr].playerGameTickets[gameID].ticketsOwned.sub(1); //remove from seller account
            allPlayersMap[gameBids[gameID][lowestSellIndex].addr].playerGameTickets[gameID].ticketsForSale = allPlayersMap[gameBids[gameID][lowestSellIndex].addr].playerGameTickets[gameID].ticketsForSale.sub(1);  //remove from seller account          
            allPlayersMap[gameBids[gameID][lowestSellIndex].addr].balance = allPlayersMap[gameBids[gameID][lowestSellIndex].addr].balance.add(bidAmount); //add to seller account                
            gameBids[gameID][lowestSellIndex].highestBidWEI = bidAmount; //set the new highest bid

            //adjust the all games variable //may e this
            for(uint256 j = 0; j < allGames[gameID].tickets.length; j++){
                if(allGames[gameID].tickets[j] == gameBids[gameID][lowestSellIndex].addr){
                    allGames[gameID].tickets[j] = msg.sender;
                    break;
                }
            }
            oldOwner = gameBids[gameID][lowestSellIndex].addr;
            gameBids[gameID][lowestSellIndex].addr = msg.sender; //set the new owner
            allPlayersMap[oldOwner].lifetimeHPBGained = allPlayersMap[oldOwner].lifetimeHPBGained.add(bidAmount);
            allPlayersMap[msg.sender].lifetimeHPBSpent = allPlayersMap[msg.sender].lifetimeHPBSpent.add(bidAmount.add(fee));

            //increase time by 5 blocks
            if(block.number + 5 > allGames[gameID].blockCountActionReadyIndex){
                allGames[gameID].blockCountActionReadyIndex = 5 + block.number;
            } 
            emit PlaceBid(gameID, getAliasIfSet(msg.sender), allGames[gameID].name, getAliasIfSet(oldOwner), getAliasIfSet(msg.sender), bidAmount, allGames[gameID].blockCountActionReadyIndex);
            
        } 
        else{
            emit PlaceBid(gameID, getAliasIfSet(msg.sender), allGames[gameID].name, getAliasIfSet(msg.sender), getAliasIfSet(msg.sender), bidAmount, allGames[gameID].blockCountActionReadyIndex); //bid was not high enough to be accepted
        }
        return found;
    }
    
    
    function getGameCount() external view returns(uint256 gameCount, uint256 activeGames){
        return (allGames.length, activeGameCount);
    }

    function getGameByID(uint256 gameID) public view returns(Game memory){
        Game memory copy = allGames[gameID];
        address payable[] memory p;
        copy.tickets = p;
        return copy;
    }
    
}



    
    