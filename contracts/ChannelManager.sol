pragma solidity ^0.4.18;

import "./interpreters/InterpreterInterface.sol";
// import "./lib/ECRecovery.sol";

contract ChannelManager {
    bool public judgeRes = true;
    address[] public _tempSigs;
    uint public _length;

    struct Channel
    {
        uint256 bond;
        uint256 bonded;
        InterpreterInterface interpreter;
        uint256 settlementPeriodLength;
        uint256 settlementPeriodEnd;
        uint8[3] booleans; // ['isChannelOpen', 'settlingPeriodStarted', 'judgeResolution']
        address[2] disputeAddresses; // ['challengedParty', 'fraudSubmitter']
        bytes state;
    }

    mapping(bytes32 => Channel) channels;

    uint256 public numChannels = 0;

    event ChannelCreated(bytes32 channelId, address indexed initiator);

    function openChannel(
        uint _bond, 
        uint _settlementPeriod, 
        address _interpreter,
        bytes _data,
        uint8 _v,
        bytes32 _r,
        bytes32 _s) 
        public 
        payable 
    {
        InterpreterInterface candidateInterpreterContract = InterpreterInterface(_interpreter);

        // NOTE: verify that a contract is what we expect - https://github.com/Lunyr/crowdsale-contracts/blob/cfadd15986c30521d8ba7d5b6f57b4fefcc7ac38/contracts/LunyrToken.sol#L117
        require(candidateInterpreterContract.isInterpreter());

        // check the account opening a channel signed the initial state
        address s = _getSig(_data, _v, _r, _s);
        require(s == msg.sender);

        // make sure the sig matches the address in state
        require(candidateInterpreterContract.initState(_data));
        require(candidateInterpreterContract.isAddressInState(s));

        // send bond to the interpreter contract. This contract will read agreed upon state 
        // and settle any outcomes of state. ie paying a wager on a game or settling a payment channel
        candidateInterpreterContract.transfer(msg.value);

        // not running judge against initial state since the client counterparty can check the state
        // before agreeing to join the channel
        Channel memory _channel = Channel(
            _bond,
            msg.value,
            candidateInterpreterContract,
            _settlementPeriod,
            0,
            [0,0,1],
            [address(0x0),address(0x0)],
            _data
        );

        numChannels++;
        var _id = keccak256(now + numChannels);
        channels[_id] = _channel;


        ChannelCreated(_id, msg.sender);
    }

    // no protection for double joining, this should be reverted in the interpreter
    function joinChannel(bytes32 _id, bytes _data, uint8 _v, bytes32 _r, bytes32 _s) public payable{
        // require(channels[_id].state == _data);
        // require the channel is not open yet
        require(channels[_id].booleans[0] == 0);
        // replace bond with balance?
        //require(msg.value == channels[_id].bond);

        // check that the state is signed by the sender and sender is in the state
        address _joiningParty = _getSig(_data, _v, _r, _s);
        require(msg.sender == _joiningParty);
        require(channels[_id].interpreter.isAddressInState(_joiningParty));

        if(channels[_id].interpreter.allJoined()) {
            channels[_id].booleans[0] = 1;
        }

        channels[_id].bonded += msg.value;

        channels[_id].interpreter.transfer(msg.value);
    }

    // This updates the state stored in the channel struct
    // check that a valid state is signed by both parties
    // this only works for 2 party channels
    function checkpointState(
        bytes32 _id, 
        bytes _data, 
        uint8[] sigV,
        bytes32[] sigR,
        bytes32[] sigS)
        public 
    {

        address[] memory tempSigs = new address[](sigV.length);

        for(uint i=0; i<sigV.length; i++) {
            address participant = _getSig(_data, sigV[i], sigR[i], sigS[i]);
            tempSigs[i] = participant;
        }

        // make sure all parties have signed
        require(channels[_id].interpreter.hasAllSigs(tempSigs));

        require(channels[_id].interpreter.isSequenceHigher(_data, channels[_id].state));

        // run the judge to be sure this is a valid state transition? does this matter if it was agreed upon?
        channels[_id].state = _data;
    }

    // Fast close: Both parties agreed to close
    // check that a valid state is signed by both parties
    // change this to an optional update function to checkpoint state
    function closeChannel(
        bytes32 _id, 
        bytes _data,
        uint8[] _v,
        bytes32[] _r,
        bytes32[] _s)
        public
    {

        address[] memory tempSigs = new address[](_v.length);

        _length = tempSigs.length;

        for(uint i=0; i<_r.length; i++) {
            address participant = _getSig(_data, _v[i], _r[i], _s[i]);
            tempSigs[i] = participant;
        }

        _tempSigs = tempSigs;
        //_length = _tempSigs.length;

        // make sure all parties have signed
        require(channels[_id].interpreter.hasAllSigs(tempSigs));

        //  If the first 32 bytes of the state represent true 0x00...01 then both parties have
        // signed a close channel agreement on this representation of the state.

        // check for this sentinel value

        require(channels[_id].interpreter.isClose(_data));
        require(channels[_id].interpreter.quickClose(_data));

        // run the judge to be sure this is a valid state transition? does this matter if it was agreed upon?
        channels[_id].state = _data;
        channels[_id].booleans[0] = 0;
    }

    // Closing with the following does not need to contain a flag in state for an agreed close

    // requires judge exercised
    function closeWithChallenge(bytes32 _id) public {
        require(channels[_id].disputeAddresses[0] != 0x0);
        require(channels[_id].booleans[2] == 0);
        // have the interpreter act on the verfied incorrect state 
        channels[_id].interpreter.challenge(channels[_id].disputeAddresses[0], channels[_id].state);
        channels[_id].booleans[0] = 0;
    }

    function closeWithTimeout(bytes32 _id) public {
        require(channels[_id].settlementPeriodEnd <= now);

        // handle timeout logic
        channels[_id].interpreter.quickClose(channels[_id].state);
        channels[_id].booleans[0] = 0;
    }

    function challengeSettleState(bytes32 _id, bytes _data, uint8[] _v, bytes32[] _r, bytes32[] _s, string _method) public {
        // require the channel to be in a settling state
        require(channels[_id].booleans[1] == 1);
        require(channels[_id].settlementPeriodEnd <= now);
        uint dataLength = _data.length;

        address[] memory tempSigs = new address[](_v.length);

        for(uint i=0; i<_v.length; i++) {
            address participant = _getSig(_data, _v[i], _r[i], _s[i]);
            tempSigs[i] = participant;
        }

        // make sure all parties have signed
        require(channels[_id].interpreter.hasAllSigs(tempSigs));

        if (channels[_id].interpreter.call(bytes4(bytes32(keccak256(_method))), bytes32(32), bytes32(dataLength), _data)) {
            judgeRes = true;
            channels[_id].booleans[2] = 1;

        } else {
            judgeRes = false;
            channels[_id].booleans[2] = 0;
            channels[_id].state = _data;
        }

        require(channels[_id].booleans[2] == 1);

        // we also alow the sequence to be equal to allow continued game
        require(channels[_id].interpreter.isSequenceHigher(_data, channels[_id].state));

        channels[_id].settlementPeriodEnd = now + channels[_id].settlementPeriodLength;
        channels[_id].state = _data;
    }

    function startSettleState(bytes32 _id, string _method, uint8[] _v, bytes32[] _r, bytes32[] _s, bytes _data) public {
        require(channels[_id].booleans[1] == 0);

        uint dataLength = _data.length;

        address[] memory tempSigs = new address[](_v.length);

        for(uint i=0; i<_v.length; i++) {
            address participant = _getSig(_data, _v[i], _r[i], _s[i]);
            tempSigs[i] = participant;
        }

        // make sure all parties have signed
        require(channels[_id].interpreter.hasAllSigs(tempSigs));  

        // In order to start settling we run the judge to be sure this is a valid state transition

        if (channels[_id].interpreter.call(bytes4(bytes32(keccak256(_method))), bytes32(32), bytes32(dataLength), _data)) {
            judgeRes = true;
            channels[_id].booleans[2] = 1;

        } else {
            judgeRes = false;
            channels[_id].booleans[2] = 0;
            channels[_id].state = _data;
        }

        require(channels[_id].booleans[2] == 1);
        require(channels[_id].interpreter.isSequenceHigher(_data, channels[_id].state));

        channels[_id].booleans[1] = 1;
        channels[_id].settlementPeriodEnd = now + channels[_id].settlementPeriodLength;
        channels[_id].state = _data;
    }

    function exerciseJudge(bytes32 _id, string _method, uint8 _v, bytes32 _r, bytes32 _s, bytes _data) public {
        uint dataLength = _data.length;

        // uint256 _bonded = channels[_id].bonded;
        // channels[_id].bonded = 0;

        address challenged = _getSig(_data, _v, _r, _s);
        require(channels[_id].interpreter.isAddressInState(challenged));

        if (!channels[_id].interpreter.call(bytes4(bytes32(keccak256(_method))), bytes32(32), bytes32(dataLength), _data)) {
            judgeRes = false;
            channels[_id].booleans[2] = 0;
            channels[_id].state = _data;
            channels[_id].disputeAddresses[0] = challenged;
            channels[_id].disputeAddresses[1] = msg.sender;
        }
    }

    function getChannel(bytes32 _id)
        external
        view
        returns
    (
        uint256 bond,
        uint256 bonded,
        address interpreter,
        uint256 settlementPeriodLength,
        uint256 settlementPeriodEnd,
        uint8[3] booleans,
        address[2] disputeAddresses,
        bytes state
    ) {

        Channel storage ch = channels[_id];

        return (
            ch.bond,
            ch.bonded,
            ch.interpreter,
            ch.settlementPeriodLength,
            ch.settlementPeriodEnd,
            ch.booleans,
            ch.disputeAddresses,
            ch.state
        );
    }

    function _getSig(bytes _d, uint8 _v, bytes32 _r, bytes32 _s) internal pure returns(address) {
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 h = keccak256(_d);

        bytes32 prefixedHash = keccak256(prefix, h);

        address a = ecrecover(prefixedHash, _v, _r, _s);

        //address a = ECRecovery.recover(prefixedHash, _s);

        return(a);
    }
}